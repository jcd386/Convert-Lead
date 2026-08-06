public with sharing class WSM_FlowLeadConverter {

    @InvocableMethod(label='Convert Lead' description='Converts Leads from Flow. Returns one output per input in the same order. Check isSuccess and errorMessage on each output.' category='Lead')
    public static List<WSM_FlowLeadConverterOutputWrapper> convertLead(List<WSM_FlowLeadConverterInputWrapper> inputList) {

        List<String> candidateStatuses = new List<String>();
        Map<String, String> convertedStatuses = new Map<String, String>();
        for (LeadStatus ls : [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            candidateStatuses.add(ls.MasterLabel);
            convertedStatuses.put(ls.MasterLabel.toLowerCase(), ls.MasterLabel);
        }

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
                if (String.isNotBlank(input.accountId)) {
                    lc.setAccountId(Id.valueOf(input.accountId.trim()));
                }
                if (String.isNotBlank(input.contactId)) {
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

        applyRenames(inputList, outputList);

        return outputList;
    }

    // Post-conversion inline edits: rename the Account, Contact, and (existing)
    // Opportunity when the caller supplied new names. Rename failures never undo
    // the conversion — they surface on warningMessage with isSuccess still true.
    private static void applyRenames(List<WSM_FlowLeadConverterInputWrapper> inputList, List<WSM_FlowLeadConverterOutputWrapper> outputList) {
        Map<Id, Account> accountUpdates = new Map<Id, Account>();
        Map<Id, Contact> contactUpdates = new Map<Id, Contact>();
        Map<Id, Opportunity> oppUpdates = new Map<Id, Opportunity>();
        Map<Id, List<WSM_FlowLeadConverterOutputWrapper>> outputsByRecordId = new Map<Id, List<WSM_FlowLeadConverterOutputWrapper>>();

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadConverterInputWrapper input = inputList[i];
            WSM_FlowLeadConverterOutputWrapper output = outputList[i];
            if (output.isSuccess != true) {
                continue;
            }
            if (String.isNotBlank(input.accountName) && output.accountId != null) {
                accountUpdates.put(output.accountId, new Account(Id = output.accountId, Name = input.accountName));
                trackOutput(outputsByRecordId, output.accountId, output);
            }
            if ((String.isNotBlank(input.contactFirstName) || String.isNotBlank(input.contactLastName)) && output.contactId != null) {
                Contact con = new Contact(Id = output.contactId);
                if (String.isNotBlank(input.contactFirstName)) {
                    con.FirstName = input.contactFirstName;
                }
                if (String.isNotBlank(input.contactLastName)) {
                    con.LastName = input.contactLastName;
                }
                contactUpdates.put(output.contactId, con);
                trackOutput(outputsByRecordId, output.contactId, output);
            }
            // A new Opportunity is already named via setOpportunityName; only an
            // existing Opportunity the lead converted into needs a rename.
            if (String.isNotBlank(input.opportunityName) && String.isNotBlank(input.opportunityId) && output.opportunityId != null) {
                oppUpdates.put(output.opportunityId, new Opportunity(Id = output.opportunityId, Name = input.opportunityName));
                trackOutput(outputsByRecordId, output.opportunityId, output);
            }
        }

        applyUpdateBatch(accountUpdates.values(), outputsByRecordId);
        applyUpdateBatch(contactUpdates.values(), outputsByRecordId);
        applyUpdateBatch(oppUpdates.values(), outputsByRecordId);
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
            String warning = 'Converted, but rename of ' + updates[i].Id + ' failed: ' + String.join(errs, '; ');
            for (WSM_FlowLeadConverterOutputWrapper output : outputsByRecordId.get(updates[i].Id)) {
                output.warningMessage = output.warningMessage == null ? warning : output.warningMessage + ' | ' + warning;
            }
        }
    }
}
