@isTest
private class WSM_FlowLeadMatchFinder_Test {

    static Database.DMLOptions allowDupes() {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        return dml;
    }

    static Boolean personAccountsEnabled() {
        return Schema.SObjectType.Account.fields.getMap().containsKey('ispersonaccount');
    }

    // Suggestions come only from the org's duplicate rules, so how MANY matches come
    // back is org configuration, not something this class can assert. These tests
    // verify the contract instead: alignment, internal consistency, and no errors.
    static void assertWellFormed(WSM_FlowLeadMatchFinderOutputWrapper o) {
        System.assertNotEquals(null, o.matchedAccounts, 'matchedAccounts should never be null');
        System.assertNotEquals(null, o.matchedContacts, 'matchedContacts should never be null');
        System.assertEquals(o.matchedAccounts.size(), o.accountMatchCount, 'account count must match collection');
        System.assertEquals(o.matchedContacts.size(), o.contactMatchCount, 'contact count must match collection');
        System.assertEquals(o.accountMatchCount > 0, o.hasAccountMatches, 'hasAccountMatches must track the count');
        System.assertEquals(o.contactMatchCount > 0, o.hasContactMatches, 'hasContactMatches must track the count');
        System.assertEquals(o.accountMatchCount, o.accountOptions.size(), 'one option per matched account');
        System.assertEquals(o.contactMatchCount, o.contactOptions.size(), 'one option per matched contact');
        System.assertEquals(o.hasAccountMatches, o.matchedAccountsHtml != null, 'account HTML present iff matches');
        System.assertEquals(o.hasContactMatches, o.matchedContactsHtml != null, 'contact HTML present iff matches');

        for (Integer i = 0; i < o.accountOptions.size(); i++) {
            Account shell = o.accountOptions[i];
            System.assertEquals(String.valueOf(o.matchedAccounts[i].Id), shell.AccountNumber, 'option value is the record Id');
            System.assert(shell.Name.contains('<a href="/' + shell.AccountNumber + '"'), shell.Name);
        }
        for (Integer i = 0; i < o.contactOptions.size(); i++) {
            Account shell = o.contactOptions[i];
            System.assertEquals(String.valueOf(o.matchedContacts[i].Id), shell.AccountNumber, 'option value is the record Id');
            System.assert(shell.Name.contains('<a href="/' + shell.AccountNumber + '"'), shell.Name);
        }
    }

    @isTest
    static void testBusinessLeadReturnsWellFormedResult() {
        Account acct = new Account(Name = 'WSM Match Probe Co');
        Database.insert(acct, allowDupes());
        Contact con = new Contact(FirstName = 'Mona', LastName = 'Matchprobe',
            Email = 'mona.matchprobe@wsmprobe.example.com', AccountId = acct.Id);
        Database.insert(con, allowDupes());
        Lead ld = new Lead(FirstName = 'Mona', LastName = 'Matchprobe', Company = 'WSM Match Probe Co',
            Email = 'mona.matchprobe@wsmprobe.example.com');
        Database.insert(ld, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper input = new WSM_FlowLeadMatchFinderInputWrapper();
        input.leadId = ld.Id;

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs =
            WSM_FlowLeadMatchFinder.findMatches(new List<WSM_FlowLeadMatchFinderInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(false, outputs[0].isPersonLead, 'Lead has a Company so it is not a person lead');
        assertWellFormed(outputs[0]);
    }

    @isTest
    static void testPersonLeadIsFlaggedAndSkipsAccountMatching() {
        if (!personAccountsEnabled()) {
            return;
        }
        Lead ld = new Lead(FirstName = 'Perry', LastName = 'Personprobe',
            Email = 'perry.personprobe@wsmpa.example.com');
        Database.insert(ld, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper input = new WSM_FlowLeadMatchFinderInputWrapper();
        input.leadId = ld.Id;

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs =
            WSM_FlowLeadMatchFinder.findMatches(new List<WSM_FlowLeadMatchFinderInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(true, outputs[0].isPersonLead, 'Blank Company should flag a person lead');
        // No Company means no account name to match on, so the account pass is skipped.
        System.assertEquals(0, outputs[0].accountMatchCount);
        System.assertEquals(false, outputs[0].hasAccountMatches);
        assertWellFormed(outputs[0]);
    }

    @isTest
    static void testBulkAlignmentAndInvalidInputs() {
        Lead good = new Lead(FirstName = 'Solo', LastName = 'Nomatch', Company = 'WSM Zero Match Co 90210');
        Database.insert(good, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper valid = new WSM_FlowLeadMatchFinderInputWrapper();
        valid.leadId = good.Id;
        valid.maxResults = 3;

        WSM_FlowLeadMatchFinderInputWrapper badId = new WSM_FlowLeadMatchFinderInputWrapper();
        badId.leadId = 'not-an-id';

        WSM_FlowLeadMatchFinderInputWrapper blank = new WSM_FlowLeadMatchFinderInputWrapper();
        blank.leadId = '';

        WSM_FlowLeadMatchFinderInputWrapper missing = new WSM_FlowLeadMatchFinderInputWrapper();
        missing.leadId = '00Q000000000000AAA';

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs = WSM_FlowLeadMatchFinder.findMatches(
            new List<WSM_FlowLeadMatchFinderInputWrapper>{ valid, badId, blank, missing });
        Test.stopTest();

        System.assertEquals(4, outputs.size(), 'one output per input, in order');
        for (WSM_FlowLeadMatchFinderOutputWrapper o : outputs) {
            assertWellFormed(o);
        }
        // Rows 2-4 reference no readable Lead, so they come back empty rather than erroring.
        for (Integer i = 1; i < 4; i++) {
            System.assertEquals(0, outputs[i].accountMatchCount);
            System.assertEquals(0, outputs[i].contactMatchCount);
            System.assertEquals(false, outputs[i].isPersonLead);
        }
        System.assert(outputs[0].matchedAccounts.size() <= 3, 'maxResults caps accounts');
        System.assert(outputs[0].matchedContacts.size() <= 3, 'maxResults caps contacts');
    }

    @isTest
    static void testEmptyInputList() {
        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs =
            WSM_FlowLeadMatchFinder.findMatches(new List<WSM_FlowLeadMatchFinderInputWrapper>());
        Test.stopTest();

        System.assertEquals(0, outputs.size());
    }
}
