public with sharing class WSM_FlowLeadMatchFinder {

    @InvocableMethod(label='Find Lead Conversion Matches' description='Runs the org duplicate/matching rules against a Lead to suggest existing Accounts and Contacts to convert into. Falls back to exact name/email matching when no duplicate rules are active. Returns one output per input in the same order.' category='Lead')
    public static List<WSM_FlowLeadMatchFinderOutputWrapper> findMatches(List<WSM_FlowLeadMatchFinderInputWrapper> inputList) {

        Set<Id> leadIds = new Set<Id>();
        for (WSM_FlowLeadMatchFinderInputWrapper input : inputList) {
            if (String.isNotBlank(input.leadId)) {
                try {
                    leadIds.add(Id.valueOf(input.leadId.trim()));
                } catch (Exception e) {
                    continue;
                }
            }
        }
        Map<Id, Lead> leadsById = new Map<Id, Lead>([
            SELECT Id, FirstName, LastName, Company, Email, Phone
            FROM Lead WHERE Id IN :leadIds
        ]);

        List<WSM_FlowLeadMatchFinderOutputWrapper> outputList = new List<WSM_FlowLeadMatchFinderOutputWrapper>();
        List<Account> syntheticAccounts = new List<Account>();
        List<Contact> syntheticContacts = new List<Contact>();
        List<Integer> matchIndexes = new List<Integer>();

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadMatchFinderInputWrapper input = inputList[i];
            WSM_FlowLeadMatchFinderOutputWrapper output = new WSM_FlowLeadMatchFinderOutputWrapper();
            output.matchedAccounts = new List<Account>();
            output.matchedContacts = new List<Contact>();
            output.accountMatchCount = 0;
            output.contactMatchCount = 0;
            output.hasAccountMatches = false;
            output.hasContactMatches = false;
            outputList.add(output);

            Lead ld = String.isBlank(input.leadId) ? null : leadsById.get(safeId(input.leadId));
            if (ld == null) {
                continue;
            }
            syntheticAccounts.add(new Account(Name = ld.Company, Phone = ld.Phone));
            syntheticContacts.add(new Contact(
                FirstName = ld.FirstName,
                LastName = ld.LastName,
                Email = ld.Email,
                Phone = ld.Phone
            ));
            matchIndexes.add(i);
        }

        if (!matchIndexes.isEmpty()) {
            List<Set<Id>> accountIdsPerRow = runFindDuplicates(syntheticAccounts);
            List<Set<Id>> contactIdsPerRow = runFindDuplicates(syntheticContacts);

            for (Integer j = 0; j < matchIndexes.size(); j++) {
                Integer idx = matchIndexes[j];
                WSM_FlowLeadMatchFinderOutputWrapper output = outputList[idx];
                Lead ld = leadsById.get(safeId(inputList[idx].leadId));
                Integer maxResults = inputList[idx].maxResults == null || inputList[idx].maxResults < 1
                    ? 5 : inputList[idx].maxResults;

                // Duplicate rules are the primary source; the exact-match fallback also
                // supplements when rules exist but find nothing (e.g. the standard
                // account rule needs address data an exact-name match does not).
                Set<Id> accIds = accountIdsPerRow == null ? null : accountIdsPerRow[j];
                if (accIds == null || accIds.isEmpty()) {
                    accIds = fallbackAccountIds(ld);
                }
                Set<Id> conIds = contactIdsPerRow == null ? null : contactIdsPerRow[j];
                if (conIds == null || conIds.isEmpty()) {
                    conIds = fallbackContactIds(ld);
                }

                if (!accIds.isEmpty()) {
                    for (Account a : [SELECT Id, Name, Phone, Website, BillingCity, BillingState, OwnerId FROM Account WHERE Id IN :accIds ORDER BY LastModifiedDate DESC]) {
                        if (output.matchedAccounts.size() >= maxResults) {
                            break;
                        }
                        output.matchedAccounts.add(a);
                    }
                }
                if (!conIds.isEmpty()) {
                    for (Contact c : [SELECT Id, Name, FirstName, LastName, Email, Phone, AccountId, Account.Name FROM Contact WHERE Id IN :conIds ORDER BY LastModifiedDate DESC]) {
                        if (output.matchedContacts.size() >= maxResults) {
                            break;
                        }
                        output.matchedContacts.add(c);
                    }
                }
                output.accountMatchCount = output.matchedAccounts.size();
                output.contactMatchCount = output.matchedContacts.size();
                output.hasAccountMatches = output.accountMatchCount > 0;
                output.hasContactMatches = output.contactMatchCount > 0;
                output.matchedAccountsHtml = buildAccountsHtml(output.matchedAccounts);
                output.matchedContactsHtml = buildContactsHtml(output.matchedContacts);
            }
        }

        return outputList;
    }

    // Returns one Set<Id> of matched record Ids per input row, or null for a row
    // when duplicate rules could not be evaluated (caller applies the fallback).
    private static List<Set<Id>> runFindDuplicates(List<SObject> records) {
        List<Set<Id>> results = new List<Set<Id>>();
        try {
            List<Datacloud.FindDuplicatesResult> dupResults = Datacloud.FindDuplicates.findDuplicates(records);
            for (Datacloud.FindDuplicatesResult res : dupResults) {
                if (res.getDuplicateResults().isEmpty()) {
                    results.add(null);
                    continue;
                }
                Set<Id> ids = new Set<Id>();
                for (Datacloud.DuplicateResult dr : res.getDuplicateResults()) {
                    for (Datacloud.MatchResult mr : dr.getMatchResults()) {
                        for (Datacloud.MatchRecord rec : mr.getMatchRecords()) {
                            ids.add(rec.getRecord().Id);
                        }
                    }
                }
                results.add(ids);
            }
            return results;
        } catch (Exception e) {
            return null;
        }
    }

    private static String buildAccountsHtml(List<Account> accounts) {
        if (accounts.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Account a : accounts) {
            String detail = '';
            List<String> bits = new List<String>();
            if (String.isNotBlank(a.BillingCity)) {
                bits.add(String.isNotBlank(a.BillingState) ? a.BillingCity + ', ' + a.BillingState : a.BillingCity);
            }
            if (String.isNotBlank(a.Website)) {
                bits.add(a.Website);
            }
            if (!bits.isEmpty()) {
                detail = ' &mdash; ' + String.join(bits, ' &middot; ').escapeHtml4().replace('&amp;mdash;', '&mdash;').replace('&amp;middot;', '&middot;');
            }
            lines.add('<p><a href="/' + a.Id + '" target="_blank" rel="noopener noreferrer">' + a.Name.escapeHtml4() + '</a>' + detail + '</p>');
        }
        return String.join(lines, '');
    }

    private static String buildContactsHtml(List<Contact> contacts) {
        if (contacts.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Contact c : contacts) {
            List<String> bits = new List<String>();
            if (c.AccountId != null && String.isNotBlank(c.Account.Name)) {
                bits.add(c.Account.Name);
            }
            if (String.isNotBlank(c.Email)) {
                bits.add(c.Email);
            }
            String detail = bits.isEmpty() ? '' : ' &mdash; ' + String.join(bits, ' &middot; ').escapeHtml4().replace('&amp;middot;', '&middot;');
            lines.add('<p><a href="/' + c.Id + '" target="_blank" rel="noopener noreferrer">' + c.Name.escapeHtml4() + '</a>' + detail + '</p>');
        }
        return String.join(lines, '');
    }

    private static Set<Id> fallbackAccountIds(Lead ld) {
        Set<Id> ids = new Set<Id>();
        if (ld != null && String.isNotBlank(ld.Company)) {
            for (Account a : [SELECT Id FROM Account WHERE Name = :ld.Company LIMIT 10]) {
                ids.add(a.Id);
            }
        }
        return ids;
    }

    private static Set<Id> fallbackContactIds(Lead ld) {
        Set<Id> ids = new Set<Id>();
        if (ld == null) {
            return ids;
        }
        if (String.isNotBlank(ld.Email)) {
            for (Contact c : [SELECT Id FROM Contact WHERE Email = :ld.Email LIMIT 10]) {
                ids.add(c.Id);
            }
        }
        if (ids.isEmpty() && String.isNotBlank(ld.LastName)) {
            for (Contact c : [SELECT Id FROM Contact WHERE LastName = :ld.LastName AND FirstName = :ld.FirstName LIMIT 10]) {
                ids.add(c.Id);
            }
        }
        return ids;
    }

    private static Id safeId(String raw) {
        try {
            return Id.valueOf(raw.trim());
        } catch (Exception e) {
            return null;
        }
    }
}
