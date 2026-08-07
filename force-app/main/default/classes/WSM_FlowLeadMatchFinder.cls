public with sharing class WSM_FlowLeadMatchFinder {

    private static final Integer DEFAULT_MAX_RESULTS = 5;

    @InvocableMethod(label='Find Lead Conversion Matches' description='Runs this org\'s active duplicate/matching rules against a Lead and returns the existing Accounts and Contacts they match, to suggest conversion targets. Suggestions come only from your duplicate rules - configure matching in Setup. Returns one output per input in the same order.' category='Lead')
    public static List<WSM_FlowLeadMatchFinderOutputWrapper> findMatches(List<WSM_FlowLeadMatchFinderInputWrapper> inputList) {

        Set<Id> leadIds = new Set<Id>();
        for (WSM_FlowLeadMatchFinderInputWrapper input : inputList) {
            Id leadId = safeId(input.leadId);
            if (leadId != null) {
                leadIds.add(leadId);
            }
        }
        Map<Id, Lead> leadsById = leadIds.isEmpty()
            ? new Map<Id, Lead>()
            : new Map<Id, Lead>([
                SELECT Id, FirstName, LastName, Company, Email, Phone
                FROM Lead WHERE Id IN :leadIds
            ]);

        List<WSM_FlowLeadMatchFinderOutputWrapper> outputList = new List<WSM_FlowLeadMatchFinderOutputWrapper>();
        List<Account> syntheticAccounts = new List<Account>();
        List<Integer> accountRows = new List<Integer>();
        List<Contact> syntheticContacts = new List<Contact>();
        List<Integer> contactRows = new List<Integer>();

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadMatchFinderOutputWrapper output = new WSM_FlowLeadMatchFinderOutputWrapper();
            output.matchedAccounts = new List<Account>();
            output.matchedContacts = new List<Contact>();
            output.accountOptions = new List<Account>();
            output.contactOptions = new List<Account>();
            output.accountMatchCount = 0;
            output.contactMatchCount = 0;
            output.hasAccountMatches = false;
            output.hasContactMatches = false;
            output.isPersonLead = false;
            outputList.add(output);

            Lead ld = leadsById.get(safeId(inputList[i].leadId));
            if (ld == null) {
                continue;
            }
            // A blank Company means a person lead: Company is required on Leads in
            // orgs without Person Accounts, so a company-less lead can only exist
            // where Person Accounts are enabled.
            output.isPersonLead = String.isBlank(ld.Company);

            // Matching runs against throwaway in-memory records shaped from the Lead.
            // Nothing here is ever inserted. A company-less lead has no account name
            // to match on, so it is left out of the account pass entirely.
            if (String.isNotBlank(ld.Company)) {
                syntheticAccounts.add(new Account(Name = ld.Company, Phone = ld.Phone));
                accountRows.add(i);
            }
            syntheticContacts.add(new Contact(
                FirstName = ld.FirstName,
                LastName = ld.LastName,
                Email = ld.Email,
                Phone = ld.Phone
            ));
            contactRows.add(i);
        }

        Map<Integer, Set<Id>> accountIdsByRow = runFindDuplicates(syntheticAccounts, accountRows);
        Map<Integer, Set<Id>> contactIdsByRow = runFindDuplicates(syntheticContacts, contactRows);

        // Fetch every matched record in one query per object, whatever the batch size.
        Set<Id> allAccountIds = new Set<Id>();
        for (Set<Id> ids : accountIdsByRow.values()) {
            allAccountIds.addAll(ids);
        }
        Set<Id> allContactIds = new Set<Id>();
        for (Set<Id> ids : contactIdsByRow.values()) {
            allContactIds.addAll(ids);
        }
        List<Account> orderedAccounts = allAccountIds.isEmpty()
            ? new List<Account>()
            : [SELECT Id, Name, Phone, Website, BillingCity, BillingState, OwnerId
               FROM Account WHERE Id IN :allAccountIds ORDER BY LastModifiedDate DESC];
        List<Contact> orderedContacts = allContactIds.isEmpty()
            ? new List<Contact>()
            : [SELECT Id, Name, FirstName, LastName, Email, Phone, AccountId, Account.Name
               FROM Contact WHERE Id IN :allContactIds ORDER BY LastModifiedDate DESC];

        for (Integer i = 0; i < inputList.size(); i++) {
            WSM_FlowLeadMatchFinderOutputWrapper output = outputList[i];
            Integer maxResults = inputList[i].maxResults == null || inputList[i].maxResults < 1
                ? DEFAULT_MAX_RESULTS : inputList[i].maxResults;

            Set<Id> rowAccountIds = accountIdsByRow.get(i);
            if (rowAccountIds != null) {
                for (Account a : orderedAccounts) {
                    if (output.matchedAccounts.size() >= maxResults) {
                        break;
                    }
                    if (rowAccountIds.contains(a.Id)) {
                        output.matchedAccounts.add(a);
                    }
                }
            }
            Set<Id> rowContactIds = contactIdsByRow.get(i);
            if (rowContactIds != null) {
                for (Contact c : orderedContacts) {
                    if (output.matchedContacts.size() >= maxResults) {
                        break;
                    }
                    if (rowContactIds.contains(c.Id)) {
                        output.matchedContacts.add(c);
                    }
                }
            }

            output.accountMatchCount = output.matchedAccounts.size();
            output.contactMatchCount = output.matchedContacts.size();
            output.hasAccountMatches = output.accountMatchCount > 0;
            output.hasContactMatches = output.contactMatchCount > 0;
            output.matchedAccountsHtml = buildAccountsHtml(output.matchedAccounts);
            output.matchedContactsHtml = buildContactsHtml(output.matchedContacts);
            output.accountOptions = buildAccountOptions(output.matchedAccounts);
            output.contactOptions = buildContactOptions(output.matchedContacts);
        }

        return outputList;
    }

    // Returns matched record Ids keyed by the row each synthetic record came from.
    // A row with no matches is simply absent. If duplicate rules can't be evaluated
    // the result is empty - no suggestions, never an error.
    private static Map<Integer, Set<Id>> runFindDuplicates(List<SObject> records, List<Integer> rowIndexes) {
        Map<Integer, Set<Id>> byRow = new Map<Integer, Set<Id>>();
        if (records.isEmpty()) {
            return byRow;
        }
        try {
            List<Datacloud.FindDuplicatesResult> dupResults = Datacloud.FindDuplicates.findDuplicates(records);
            for (Integer i = 0; i < dupResults.size() && i < rowIndexes.size(); i++) {
                Set<Id> ids = new Set<Id>();
                for (Datacloud.DuplicateResult dr : dupResults[i].getDuplicateResults()) {
                    for (Datacloud.MatchResult mr : dr.getMatchResults()) {
                        for (Datacloud.MatchRecord rec : mr.getMatchRecords()) {
                            ids.add(rec.getRecord().Id);
                        }
                    }
                }
                if (!ids.isEmpty()) {
                    byRow.put(rowIndexes[i], ids);
                }
            }
        } catch (Exception e) {
            return new Map<Integer, Set<Id>>();
        }
        return byRow;
    }

    private static String buildAccountsHtml(List<Account> accounts) {
        if (accounts.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Account a : accounts) {
            lines.add('<p>' + linkLabel(a.Id, a.Name, accountDetailBits(a)) + '</p>');
        }
        return String.join(lines, '');
    }

    private static String buildContactsHtml(List<Contact> contacts) {
        if (contacts.isEmpty()) {
            return null;
        }
        List<String> lines = new List<String>();
        for (Contact c : contacts) {
            lines.add('<p>' + linkLabel(c.Id, c.Name, contactDetailBits(c)) + '</p>');
        }
        return String.join(lines, '');
    }

    // Choice option shells: Name carries a rich-text link label (the href holds
    // the target record Id, so callers can recover the exact Id from the label);
    // AccountNumber carries the target record Id as the choice value.
    private static List<Account> buildAccountOptions(List<Account> accounts) {
        List<Account> options = new List<Account>();
        for (Account a : accounts) {
            options.add(new Account(
                Name = linkLabel(a.Id, a.Name, accountDetailBits(a)).abbreviate(255),
                AccountNumber = String.valueOf(a.Id)
            ));
        }
        return options;
    }

    private static List<Account> buildContactOptions(List<Contact> contacts) {
        List<Account> options = new List<Account>();
        for (Contact c : contacts) {
            options.add(new Account(
                Name = linkLabel(c.Id, c.Name, contactDetailBits(c)).abbreviate(255),
                AccountNumber = String.valueOf(c.Id)
            ));
        }
        return options;
    }

    private static List<String> accountDetailBits(Account a) {
        List<String> bits = new List<String>();
        if (String.isNotBlank(a.BillingCity)) {
            bits.add(String.isNotBlank(a.BillingState) ? a.BillingCity + ', ' + a.BillingState : a.BillingCity);
        }
        if (String.isNotBlank(a.Website)) {
            bits.add(a.Website);
        }
        return bits;
    }

    private static List<String> contactDetailBits(Contact c) {
        List<String> bits = new List<String>();
        if (c.AccountId != null && String.isNotBlank(c.Account.Name)) {
            bits.add(c.Account.Name);
        }
        if (String.isNotBlank(c.Email)) {
            bits.add(c.Email);
        }
        return bits;
    }

    private static String linkLabel(Id targetId, String rawName, List<String> detailBits) {
        String name = (rawName == null ? '' : rawName).abbreviate(100).escapeHtml4();
        String detail = detailBits.isEmpty()
            ? ''
            : ' &mdash; ' + String.join(detailBits, ' &middot; ').abbreviate(90).escapeHtml4().replace('&amp;middot;', '&middot;');
        return '<a href="/' + targetId + '" target="_blank" rel="noopener noreferrer">' + name + '</a>' + detail;
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
}
