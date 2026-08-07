public with sharing class WSM_FlowLeadConverter {

    // Database.convertLead is documented as supporting at most 100 LeadConvert
    // objects per call; a bulk flow can hand this action up to 200 at once.
    private static final Integer CONVERT_CHUNK_SIZE = 100;
    @TestVisible
    private static Integer chunkSize = CONVERT_CHUNK_SIZE;

    private static Boolean paEnabledCache;
    private static Boolean canConvertCache;

    public class ConvertInputException extends Exception {}

    // Person Account fields (IsPersonAccount, PersonContactId, RecordType.IsPersonType)
    // do NOT exist in orgs without Person Accounts — a static reference would fail to
    // compile there and block the whole package from installing. Every PA reference in
    // this class is therefore dynamic and gated on this runtime check.
    private static Boolean personAccountsEnabled() {
        if (paEnabledCache == null) {
            paEnabledCache = Schema.SObjectType.Account.fields.getMap().containsKey('ispersonaccount');
        }
        return paEnabledCache;
    }

    // Apex runs in system context, so Database.convertLead succeeds even for a user
    // without "Convert Leads". Callers who want the platform's own gate can opt in.
    private static Boolean runningUserCanConvertLeads() {
        if (canConvertCache == null) {
            canConvertCache = ![
                SELECT Id FROM PermissionSetAssignment
                WHERE AssigneeId = :UserInfo.getUserId()
                AND PermissionSet.PermissionsConvertLeads = true
                LIMIT 1
            ].isEmpty();
        }
        return canConvertCache;
    }

    private static Map<Id, SObject> loadAccountPersonInfo(Set<Id> accountIds) {
        Map<Id, SObject> byId = new Map<Id, SObject>();
        if (!personAccountsEnabled() || accountIds.isEmpty()) {
            return byId;
        }
        for (SObject a : Database.query('SELECT Id, IsPersonAccount, PersonContactId FROM Account WHERE Id IN :accountIds')) {
            byId.put((Id) a.get('Id'), a);
        }
        return byId;
    }

    private static Boolean isPersonAccount(Map<Id, SObject> accountInfo, Id accountId) {
        if (accountId == null) {
            return false;
        }
        SObject a = accountInfo.get(accountId);
        return a != null && a.get('IsPersonAccount') == true;
    }

    private static void addWarning(WSM_FlowLeadConverterOutputWrapper output, String warning) {
        if (output.warningMessage == null) {
            output.warningMessage = warning;
        } else if (!output.warningMessage.contains(warning)) {
            output.warningMessage += ' | ' + warning;
        }
    }

    private static Id safeId(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        try {
            return Id.valueOf(raw.trim());
        } catch (Exception e) {
            return null;
        }
    }

    // Well-formed Ids of the wrong object produce opaque platform errors ("invalid
    // cross reference id"), so check the type up front and say which input is wrong.
    private static Id typedId(String raw, List<Schema.SObjectType> allowed, String label) {
        if (String.isBlank(raw)) {
            return null;
        }
        Id parsed;
        try {
            parsed = Id.valueOf(raw.trim());
        } catch (Exception e) {
            throw new ConvertInputException(label + ' is not a valid Salesforce Id: "' + raw + '".');
        }
        Schema.SObjectType actual = parsed.getSObjectType();
        for (Schema.SObjectType t : allowed) {
            if (actual == t) {
                return parsed;
            }
        }
        List<String> names = new List<String>();
        for (Schema.SObjectType t : allowed) {
            names.add(String.valueOf(t));
        }
        throw new ConvertInputException(label + ' must be a ' + String.join(names, ' or ')
            + ' Id, but a ' + actual + ' Id was supplied.');
    }

    @InvocableMethod(label='Convert Lead' description='Converts Leads from Flow. Returns one output per input in the same order. Check isSuccess and errorMessage on each output. Person Account aware when Person Accounts are enabled.' category='Lead')
    public static List<WSM_FlowLeadConverterOutputWrapper> convertLead(List<WSM_FlowLeadConverterInputWrapper> inputList) {

        List<String> candidateStatuses = new List<String>();
        Map<String, String> convertedStatuses = new Map<String, String>();
        for (LeadStatus ls : [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            candidateStatuses.add(ls.MasterLabel);
            convertedStatuses.put(ls.MasterLabel.toLowerCase(), ls.MasterLabel);
        }

        Boolean anyEnforcement = false;
        for (WSM_FlowLeadConverterInputWrapper input : inputList) {
            if (input.enforceUserPermissions == true) {
                anyEnforcement = true;
                break;
            }
        }
        Boolean userCanConvert = anyEnforcement ? runningUserCanConvertLeads() : true;

        // Pre-load target accounts so a Person Account can be supplied on its own.
        Set<Id> targetAccountIds = new Set<Id>();
        for (WSM_FlowLeadConverterInputWrapper input : inputList) {
            Id acctId = safeId(input.accountId);
            if (acctId != null && acctId.getSObjectType() == Account.SObjectType) {
                targetAccountIds.add(acctId);
            }
        }
        Map<Id, SObject> targetAccountInfo = loadAccountPersonInfo(targetAccountIds);

        List<WSM_FlowLeadConverterOutputWrapper> outputList = new List<WSM_FlowLeadConverterOutputWrapper>();
        List<Database.LeadConvert> leadConverts = new List<Database.LeadConvert>();
        List<Integer> convertIndexes = new List<Integer>();
        // Inputs with no status supplied are eligible for auto-retry across all
        // converted statuses, because an org-wide converted status can still be
        // invalid for a lead's record type business process.
        Set<Integer> autoStatusIndexes = new Set<Integer>();

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadConverterInputWrapper input = inputList[i];
            WSM_FlowLeadConverterOutputWrapper output = new WSM_FlowLeadConverterOutputWrapper();
            output.isSuccess = false;
            output.isPersonAccount = false;
            outputList.add(output);

            if (input.enforceUserPermissions == true && !userCanConvert) {
                output.errorMessage = 'You do not have the "Convert Leads" permission.';
                continue;
            }

            Boolean statusBlank = String.isBlank(input.ConvertedStatusName);
            String resolvedStatus;
            if (statusBlank) {
                resolvedStatus = candidateStatuses.isEmpty() ? null : candidateStatuses[0];
            } else {
                resolvedStatus = convertedStatuses.get(input.ConvertedStatusName.trim().toLowerCase());
            }

            if (resolvedStatus == null) {
                output.errorMessage = statusBlank
                    ? 'No converted Lead Status exists in this org.'
                    : 'No converted Lead Status named "' + input.ConvertedStatusName + '" exists. Valid values: ' + String.join(convertedStatuses.values(), ', ');
                continue;
            }
            if (String.isBlank(input.leadId)) {
                output.errorMessage = 'leadId is required.';
                continue;
            }

            try {
                Database.LeadConvert lc = new Database.LeadConvert();
                lc.setLeadId(typedId(input.leadId, new List<Schema.SObjectType>{ Lead.SObjectType }, 'Lead Id'));
                lc.setConvertedStatus(resolvedStatus);
                lc.setDoNotCreateOpportunity(input.doNotCreateOpp == true);

                Id targetAccountId = typedId(input.accountId, new List<Schema.SObjectType>{ Account.SObjectType }, 'Existing Account Id');
                if (targetAccountId != null) {
                    lc.setAccountId(targetAccountId);
                }

                // Per the Apex Reference, converting into a Person Account must specify
                // ONLY the account - passing a Contact Id there is documented to error.
                Id targetContactId = typedId(input.contactId, new List<Schema.SObjectType>{ Contact.SObjectType }, 'Existing Contact Id');
                if (isPersonAccount(targetAccountInfo, targetAccountId)) {
                    if (targetContactId != null) {
                        addWarning(output, 'Existing Contact Id is ignored when converting into a Person Account - the person Contact is implied by the account.');
                    }
                } else if (targetContactId != null) {
                    lc.setContactId(targetContactId);
                }

                Id targetOppId = typedId(input.opportunityId, new List<Schema.SObjectType>{ Opportunity.SObjectType }, 'Existing Opportunity Id');
                if (targetOppId != null) {
                    lc.setOpportunityId(targetOppId);
                }
                Id personAcctId = typedId(input.personAccountId, new List<Schema.SObjectType>{ Account.SObjectType }, 'Person Account Id');
                if (personAcctId != null) {
                    lc.setRelatedPersonAccountId(personAcctId);
                }
                // An owner can be a User or a Queue (Group).
                Id ownerId = typedId(input.ownerId, new List<Schema.SObjectType>{ User.SObjectType, Group.SObjectType }, 'New Owner Id');
                if (ownerId != null) {
                    lc.setOwnerId(ownerId);
                }
                // The platform rejects a LeadConvert carrying both opportunityId and
                // opportunityName; when converting into an existing Opportunity the
                // rename happens post-convert in applyRenames instead.
                if (String.isNotBlank(input.opportunityName) && targetOppId == null) {
                    lc.setOpportunityName(input.opportunityName);
                }
                if (input.sendNotificationEmail == true) {
                    lc.setSendNotificationEmail(true);
                }
                if (input.overwriteLeadSource == true) {
                    lc.setOverwriteLeadSource(true);
                }
                leadConverts.add(lc);
                convertIndexes.add(i);
                if (statusBlank) {
                    autoStatusIndexes.add(i);
                }
            } catch (ConvertInputException e) {
                output.errorMessage = e.getMessage();
            } catch (Exception e) {
                output.errorMessage = 'Invalid input: ' + e.getMessage();
            }
        }

        // Alert-mode duplicate rules block convertLead in the API context even
        // though the standard convert UI lets users save through them. allowSave
        // restores that parity; block-mode rules still block.
        Database.DMLOptions convertOptions = new Database.DMLOptions();
        convertOptions.optAllOrNone = false;
        convertOptions.duplicateRuleHeader.allowSave = true;

        List<Database.LeadConvert> pending = leadConverts;
        List<Integer> pendingIndexes = convertIndexes;
        Integer round = 0;
        while (!pending.isEmpty()) {
            List<Database.LeadConvert> retries = new List<Database.LeadConvert>();
            List<Integer> retryIndexes = new List<Integer>();

            for (Integer offset = 0; offset < pending.size(); offset += chunkSize) {
                Integer stop = Math.min(offset + chunkSize, pending.size());
                List<Database.LeadConvert> chunk = new List<Database.LeadConvert>();
                List<Integer> chunkIndexes = new List<Integer>();
                for (Integer k = offset; k < stop; k++) {
                    chunk.add(pending[k]);
                    chunkIndexes.add(pendingIndexes[k]);
                }

                List<Database.LeadConvertResult> results = Database.convertLead(chunk, convertOptions);
                for (Integer j = 0; j < results.size(); j++) {
                    Integer idx = chunkIndexes[j];
                    WSM_FlowLeadConverterOutputWrapper output = outputList[idx];
                    Database.LeadConvertResult res = results[j];

                    if (res.isSuccess()) {
                        output.isSuccess = true;
                        output.errorMessage = null;
                        output.accountId = res.getAccountId();
                        output.contactId = res.getContactId();
                        output.opportunityId = res.getOpportunityId();
                        output.personAccountId = res.getRelatedPersonAccountId();
                        continue;
                    }
                    // Only a status rejection is worth retrying under a different
                    // status. Retrying every failure wasted a DML statement per
                    // candidate and could report a status error in place of the
                    // real cause.
                    Boolean retryable = autoStatusIndexes.contains(idx)
                        && round + 1 < candidateStatuses.size()
                        && isInvalidStatusError(res);
                    if (retryable) {
                        chunk[j].setConvertedStatus(candidateStatuses[round + 1]);
                        retries.add(chunk[j]);
                        retryIndexes.add(idx);
                    } else {
                        List<String> errs = new List<String>();
                        for (Database.Error err : res.getErrors()) {
                            errs.add(err.getMessage());
                        }
                        output.errorMessage = String.join(errs, '; ');
                    }
                }
            }

            pending = retries;
            pendingIndexes = retryIndexes;
            round++;
        }

        // Flag which conversions produced a Person Account. getRelatedPersonAccountId()
        // only populates when converting INTO an existing person account, so a newly
        // created person account is otherwise indistinguishable from a business one.
        Set<Id> convertedAccountIds = new Set<Id>();
        for (WSM_FlowLeadConverterOutputWrapper output : outputList) {
            if (output.isSuccess == true && output.accountId != null) {
                convertedAccountIds.add(output.accountId);
            }
        }
        Map<Id, SObject> convertedAccountInfo = loadAccountPersonInfo(convertedAccountIds);
        for (WSM_FlowLeadConverterOutputWrapper output : outputList) {
            if (output.isSuccess == true) {
                output.isPersonAccount = isPersonAccount(convertedAccountInfo, output.accountId);
            }
        }

        applyRenames(inputList, outputList, convertedAccountInfo);

        return outputList;
    }

    private static Boolean isInvalidStatusError(Database.LeadConvertResult res) {
        for (Database.Error err : res.getErrors()) {
            if (err.getStatusCode() == System.StatusCode.INVALID_STATUS) {
                return true;
            }
        }
        return false;
    }

    // Post-conversion inline edits: rename the Account, Contact, and (existing)
    // Opportunity when the caller supplied new names. Rename failures never undo
    // the conversion — they surface on warningMessage with isSuccess still true.
    private static void applyRenames(
        List<WSM_FlowLeadConverterInputWrapper> inputList,
        List<WSM_FlowLeadConverterOutputWrapper> outputList,
        Map<Id, SObject> convertedAccountInfo
    ) {
        Map<Id, SObject> accountUpdates = new Map<Id, SObject>();
        Map<Id, SObject> contactUpdates = new Map<Id, SObject>();
        Map<Id, SObject> oppUpdates = new Map<Id, SObject>();
        Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId = new Map<Id, List<WSM_FlowLeadConverterOutputWrapper>>();
        RecordTypeCatalog catalog = loadRecordTypes(inputList);
        Boolean enforce = false;

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadConverterInputWrapper input = inputList[i];
            WSM_FlowLeadConverterOutputWrapper output = outputList[i];
            if (output.isSuccess != true) {
                continue;
            }
            if (input.enforceUserPermissions == true) {
                enforce = true;
            }
            Boolean acctIsPerson = isPersonAccount(convertedAccountInfo, output.accountId);

            Id acctRt = resolveRecordType(catalog, 'Account', input.accountRecordType, output);
            Id conRt = resolveRecordType(catalog, 'Contact', input.contactRecordType, output);
            Id oppRt = resolveRecordType(catalog, 'Opportunity', input.opportunityRecordType, output);

            // A Person Account requires a person-type record type and a business
            // account requires a business one; swapping them is rejected by the
            // platform, so catch it here with a message that explains why.
            if (acctRt != null && catalog.personTypeKnown) {
                Boolean rtIsPerson = catalog.personTypeIds.contains(acctRt);
                if (rtIsPerson != acctIsPerson) {
                    addWarning(output, 'Account record type "' + input.accountRecordType + '" is a '
                        + (rtIsPerson ? 'Person Account' : 'business account') + ' type but the converted Account is a '
                        + (acctIsPerson ? 'Person Account' : 'business account') + ' - record type not changed.');
                    acctRt = null;
                }
            }

            // Account.Name is a read-only compound field on a Person Account (it is
            // derived from the person's first/last name), so redirect the caller.
            String acctNameToSet = input.accountName;
            if (acctIsPerson && String.isNotBlank(acctNameToSet)) {
                addWarning(output, 'Account Name can\'t be set on a Person Account - its Name comes from the person\'s name. Use Contact First Name / Contact Last Name instead.');
                acctNameToSet = null;
            }

            Map<String, Object> acctFields = new Map<String, Object>();
            if (String.isNotBlank(acctNameToSet)) {
                acctFields.put('Name', acctNameToSet);
            }
            if (acctRt != null) {
                acctFields.put('RecordTypeId', acctRt);
            }
            if (!acctFields.isEmpty() && output.accountId != null) {
                stageUpdate(accountUpdates, outputsByRecordId, output.accountId, 'Account', acctFields, output);
            }

            // Renaming the Contact is the supported way to rename a Person Account:
            // writing the person Contact's first/last name updates the account Name.
            Map<String, Object> conFields = new Map<String, Object>();
            if (String.isNotBlank(input.contactFirstName)) {
                conFields.put('FirstName', input.contactFirstName);
            }
            if (String.isNotBlank(input.contactLastName)) {
                conFields.put('LastName', input.contactLastName);
            }
            if (conRt != null) {
                if (acctIsPerson) {
                    addWarning(output, 'Contact record type is controlled by the Person Account record type - record type not changed on the person Contact.');
                } else {
                    conFields.put('RecordTypeId', conRt);
                }
            }
            if (!conFields.isEmpty() && output.contactId != null) {
                stageUpdate(contactUpdates, outputsByRecordId, output.contactId, 'Contact', conFields, output);
            }

            // A new Opportunity is already named via setOpportunityName; only an
            // existing Opportunity the lead converted into needs a rename.
            Map<String, Object> oppFields = new Map<String, Object>();
            if (String.isNotBlank(input.opportunityName) && String.isNotBlank(input.opportunityId)) {
                oppFields.put('Name', input.opportunityName);
            }
            if (oppRt != null) {
                oppFields.put('RecordTypeId', oppRt);
            }
            if (!oppFields.isEmpty() && output.opportunityId != null) {
                stageUpdate(oppUpdates, outputsByRecordId, output.opportunityId, 'Opportunity', oppFields, output);
            }
        }

        applyUpdateBatch(accountUpdates.values(), outputsByRecordId, enforce);
        applyUpdateBatch(contactUpdates.values(), outputsByRecordId, enforce);
        applyUpdateBatch(oppUpdates.values(), outputsByRecordId, enforce);
    }

    // Two Leads in one batch can converge on the same Account or Opportunity. First
    // value wins and every output touching that record is told what was ignored,
    // rather than one caller's rename silently disappearing.
    private static void stageUpdate(
        Map<Id, SObject> updates,
        Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId,
        Id recordId,
        String objectType,
        Map<String, Object> fieldValues,
        WSM_FlowLeadConverterOutputWrapper output
    ) {
        SObject rec = updates.get(recordId);
        if (rec == null) {
            rec = Schema.getGlobalDescribe().get(objectType).newSObject();
            rec.put('Id', recordId);
            updates.put(recordId, rec);
        }
        for (String fieldName : fieldValues.keySet()) {
            Object requested = fieldValues.get(fieldName);
            Object existing = rec.get(fieldName);
            if (existing != null && existing != requested) {
                String warning = 'Another Lead in the same batch set ' + objectType + '.' + fieldName
                    + ' on ' + recordId + ' to "' + existing + '"; "' + requested + '" was ignored.';
                addWarning(output, warning);
                if (outputsByRecordId.containsKey(recordId)) {
                    for (WSM_FlowLeadConverterOutputWrapper prior : outputsByRecordId.get(recordId)) {
                        addWarning(prior, warning);
                    }
                }
                continue;
            }
            rec.put(fieldName, requested);
        }
        trackOutput(outputsByRecordId, recordId, output);
    }

    private class RecordTypeCatalog {
        Map<String, Map<String, Id>> byObject = new Map<String, Map<String, Id>>();
        Set<Id> personTypeIds = new Set<Id>();
        Boolean personTypeKnown = false;
    }

    // Record type inputs accept an Id, DeveloperName, or label. Resolution is
    // case-insensitive; unresolvable values surface on warningMessage.
    private static RecordTypeCatalog loadRecordTypes(List<WSM_FlowLeadConverterInputWrapper> inputList) {
        RecordTypeCatalog catalog = new RecordTypeCatalog();
        Boolean anyRequested = false;
        for (WSM_FlowLeadConverterInputWrapper input : inputList) {
            if (String.isNotBlank(input.accountRecordType) || String.isNotBlank(input.contactRecordType) || String.isNotBlank(input.opportunityRecordType)) {
                anyRequested = true;
                break;
            }
        }
        if (!anyRequested) {
            return catalog;
        }
        // RecordType.IsPersonType only exists when Person Accounts are enabled.
        catalog.personTypeKnown = Schema.SObjectType.RecordType.fields.getMap().containsKey('ispersontype');
        String soql = 'SELECT Id, SobjectType, DeveloperName, Name'
            + (catalog.personTypeKnown ? ', IsPersonType' : '')
            + ' FROM RecordType WHERE SobjectType IN (\'Account\', \'Contact\', \'Opportunity\') AND IsActive = true';
        for (SObject rt : Database.query(soql)) {
            String sobjectType = String.valueOf(rt.get('SobjectType'));
            if (!catalog.byObject.containsKey(sobjectType)) {
                catalog.byObject.put(sobjectType, new Map<String, Id>());
            }
            Id rtId = (Id) rt.get('Id');
            Map<String, Id> lookup = catalog.byObject.get(sobjectType);
            lookup.put(String.valueOf(rtId).toLowerCase(), rtId);
            lookup.put(String.valueOf(rtId).left(15).toLowerCase(), rtId);
            lookup.put(String.valueOf(rt.get('DeveloperName')).toLowerCase(), rtId);
            lookup.put(String.valueOf(rt.get('Name')).toLowerCase(), rtId);
            if (catalog.personTypeKnown && rt.get('IsPersonType') == true) {
                catalog.personTypeIds.add(rtId);
            }
        }
        return catalog;
    }

    private static Id resolveRecordType(RecordTypeCatalog catalog, String objectType, String requested, WSM_FlowLeadConverterOutputWrapper output) {
        if (String.isBlank(requested)) {
            return null;
        }
        Map<String, Id> lookup = catalog.byObject.get(objectType);
        Id resolved = lookup == null ? null : lookup.get(requested.trim().toLowerCase());
        if (resolved == null && output.isSuccess == true) {
            addWarning(output, 'No active ' + objectType + ' record type matches "' + requested + '" - record type not changed.');
        }
        return resolved;
    }

    private static void trackOutput(Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId, Id recordId, WSM_FlowLeadConverterOutputWrapper output) {
        if (!outputsByRecordId.containsKey(recordId)) {
            outputsByRecordId.put(recordId, new List<WSM_FlowLeadConverterOutputWrapper>());
        }
        outputsByRecordId.get(recordId).add(output);
    }

    private static void applyUpdateBatch(
        List<SObject> updates,
        Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId,
        Boolean enforceUserPermissions
    ) {
        if (updates.isEmpty()) {
            return;
        }
        // The post-conversion writes run in system context like the rest of Apex.
        // When the caller opts in, drop any field the running user cannot edit and
        // tell them, rather than quietly writing past their field-level security.
        if (enforceUserPermissions) {
            SObjectAccessDecision decision;
            try {
                // enforceRootObjectCRUD must stay FALSE: with it on, a user who lacks
                // object-level access gets a NoAccessException thrown here, which would
                // fault the flow AFTER the conversion has already committed. Passing
                // false strips the fields instead, and any object-level denial then
                // surfaces through the normal DML failure path below.
                decision = Security.stripInaccessible(AccessType.UPDATABLE, updates, false);
            } catch (Exception e) {
                String stripWarning = 'Converted, but post-conversion updates were skipped: ' + e.getMessage();
                for (SObject rec : updates) {
                    if (outputsByRecordId.containsKey(rec.Id)) {
                        for (WSM_FlowLeadConverterOutputWrapper output : outputsByRecordId.get(rec.Id)) {
                            addWarning(output, stripWarning);
                        }
                    }
                }
                return;
            }
            Map<String, Set<String>> removed = decision.getRemovedFields();
            if (!removed.isEmpty()) {
                List<String> parts = new List<String>();
                for (String obj : removed.keySet()) {
                    parts.add(obj + ': ' + String.join(new List<String>(removed.get(obj)), ', '));
                }
                String warning = 'Field-level security stopped these post-conversion updates - ' + String.join(parts, '; ') + '.';
                for (SObject rec : updates) {
                    if (outputsByRecordId.containsKey(rec.Id)) {
                        for (WSM_FlowLeadConverterOutputWrapper output : outputsByRecordId.get(rec.Id)) {
                            addWarning(output, warning);
                        }
                    }
                }
            }
            updates = decision.getRecords();
            if (updates.isEmpty()) {
                return;
            }
        }

        Database.DMLOptions renameOptions = new Database.DMLOptions();
        renameOptions.optAllOrNone = false;
        renameOptions.duplicateRuleHeader.allowSave = true;
        List<Database.SaveResult> results = Database.update(updates, renameOptions);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            List<String> errs = new List<String>();
            for (Database.Error err : results[i].getErrors()) {
                errs.add(err.getMessage());
            }
            String warning = 'Converted, but post-conversion update of ' + updates[i].Id + ' failed: ' + String.join(errs, '; ');
            if (outputsByRecordId.containsKey(updates[i].Id)) {
                for (WSM_FlowLeadConverterOutputWrapper output : outputsByRecordId.get(updates[i].Id)) {
                    addWarning(output, warning);
                }
            }
        }
    }
}
