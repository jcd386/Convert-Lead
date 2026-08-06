public with sharing class WSM_FlowLeadConverter {

    private static Boolean paEnabledCache;

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
        output.warningMessage = output.warningMessage == null ? warning : output.warningMessage + ' | ' + warning;
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

    @InvocableMethod(label='Convert Lead' description='Converts Leads from Flow. Returns one output per input in the same order. Check isSuccess and errorMessage on each output. Person Account aware when Person Accounts are enabled.' category='Lead')
    public static List<WSM_FlowLeadConverterOutputWrapper> convertLead(List<WSM_FlowLeadConverterInputWrapper> inputList) {

        List<String> candidateStatuses = new List<String>();
        Map<String, String> convertedStatuses = new Map<String, String>();
        for (LeadStatus ls : [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            candidateStatuses.add(ls.MasterLabel);
            convertedStatuses.put(ls.MasterLabel.toLowerCase(), ls.MasterLabel);
        }

        // Pre-load target accounts so a Person Account can be supplied on its own:
        // its PersonContactId fills in the Contact, which the platform requires.
        Set<Id> targetAccountIds = new Set<Id>();
        for (WSM_FlowLeadConverterInputWrapper input : inputList) {
            Id acctId = safeId(input.accountId);
            if (acctId != null) {
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
                lc.setLeadId(Id.valueOf(input.leadId.trim()));
                lc.setConvertedStatus(resolvedStatus);
                lc.setDoNotCreateOpportunity(input.doNotCreateOpp == true);

                Id targetAccountId = safeId(input.accountId);
                if (String.isNotBlank(input.accountId)) {
                    lc.setAccountId(Id.valueOf(input.accountId.trim()));
                }

                // Converting into an existing Person Account requires its person
                // Contact; resolve it so callers only have to supply the account.
                Id targetContactId = safeId(input.contactId);
                if (targetContactId == null && isPersonAccount(targetAccountInfo, targetAccountId)) {
                    targetContactId = (Id) targetAccountInfo.get(targetAccountId).get('PersonContactId');
                }
                if (targetContactId != null) {
                    lc.setContactId(targetContactId);
                } else if (String.isNotBlank(input.contactId)) {
                    lc.setContactId(Id.valueOf(input.contactId.trim()));
                }

                if (String.isNotBlank(input.opportunityId)) {
                    lc.setOpportunityId(Id.valueOf(input.opportunityId.trim()));
                }
                if (String.isNotBlank(input.personAccountId)) {
                    lc.setRelatedPersonAccountId(Id.valueOf(input.personAccountId.trim()));
                }
                if (String.isNotBlank(input.ownerId)) {
                    lc.setOwnerId(Id.valueOf(input.ownerId.trim()));
                }
                // The platform rejects a LeadConvert carrying both opportunityId and
                // opportunityName; when converting into an existing Opportunity the
                // rename happens post-convert in applyRenames instead.
                if (String.isNotBlank(input.opportunityName) && String.isBlank(input.opportunityId)) {
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
            List<Database.LeadConvertResult> results = Database.convertLead(pending, convertOptions);
            List<Database.LeadConvert> retries = new List<Database.LeadConvert>();
            List<Integer> retryIndexes = new List<Integer>();

            for (Integer j = 0; j < results.size(); j++) {
                Integer idx = pendingIndexes[j];
                WSM_FlowLeadConverterOutputWrapper output = outputList[idx];
                Database.LeadConvertResult res = results[j];

                if (res.isSuccess()) {
                    output.isSuccess = true;
                    output.errorMessage = null;
                    output.accountId = res.getAccountId();
                    output.contactId = res.getContactId();
                    output.opportunityId = res.getOpportunityId();
                    output.personAccountId = res.getRelatedPersonAccountId();
                } else if (autoStatusIndexes.contains(idx) && round + 1 < candidateStatuses.size()) {
                    pending[j].setConvertedStatus(candidateStatuses[round + 1]);
                    retries.add(pending[j]);
                    retryIndexes.add(idx);
                } else {
                    List<String> errs = new List<String>();
                    for (Database.Error err : res.getErrors()) {
                        errs.add(err.getMessage());
                    }
                    output.errorMessage = String.join(errs, '; ');
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

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadConverterInputWrapper input = inputList[i];
            WSM_FlowLeadConverterOutputWrapper output = outputList[i];
            if (output.isSuccess != true) {
                continue;
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

            if ((String.isNotBlank(acctNameToSet) || acctRt != null) && output.accountId != null) {
                SObject acct = Schema.getGlobalDescribe().get('Account').newSObject();
                acct.put('Id', output.accountId);
                if (String.isNotBlank(acctNameToSet)) {
                    acct.put('Name', acctNameToSet);
                }
                if (acctRt != null) {
                    acct.put('RecordTypeId', acctRt);
                }
                accountUpdates.put(output.accountId, acct);
                trackOutput(outputsByRecordId, output.accountId, output);
            }

            // Renaming the Contact is the supported way to rename a Person Account:
            // writing the person Contact's first/last name updates the account Name.
            if ((String.isNotBlank(input.contactFirstName) || String.isNotBlank(input.contactLastName) || conRt != null) && output.contactId != null) {
                SObject con = Schema.getGlobalDescribe().get('Contact').newSObject();
                con.put('Id', output.contactId);
                if (String.isNotBlank(input.contactFirstName)) {
                    con.put('FirstName', input.contactFirstName);
                }
                if (String.isNotBlank(input.contactLastName)) {
                    con.put('LastName', input.contactLastName);
                }
                if (conRt != null) {
                    if (acctIsPerson) {
                        addWarning(output, 'Contact record type is controlled by the Person Account record type - record type not changed on the person Contact.');
                    } else {
                        con.put('RecordTypeId', conRt);
                    }
                }
                contactUpdates.put(output.contactId, con);
                trackOutput(outputsByRecordId, output.contactId, output);
            }

            // A new Opportunity is already named via setOpportunityName; only an
            // existing Opportunity the lead converted into needs a rename.
            Boolean renameOpp = String.isNotBlank(input.opportunityName) && String.isNotBlank(input.opportunityId);
            if ((renameOpp || oppRt != null) && output.opportunityId != null) {
                SObject opp = Schema.getGlobalDescribe().get('Opportunity').newSObject();
                opp.put('Id', output.opportunityId);
                if (renameOpp) {
                    opp.put('Name', input.opportunityName);
                }
                if (oppRt != null) {
                    opp.put('RecordTypeId', oppRt);
                }
                oppUpdates.put(output.opportunityId, opp);
                trackOutput(outputsByRecordId, output.opportunityId, output);
            }
        }

        applyUpdateBatch(accountUpdates.values(), outputsByRecordId);
        applyUpdateBatch(contactUpdates.values(), outputsByRecordId);
        applyUpdateBatch(oppUpdates.values(), outputsByRecordId);
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

    private static void applyUpdateBatch(List<SObject> updates, Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId) {
        if (updates.isEmpty()) {
            return;
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
            for (WSM_FlowLeadConverterOutputWrapper output : outputsByRecordId.get(updates[i].Id)) {
                addWarning(output, warning);
            }
        }
    }
}
