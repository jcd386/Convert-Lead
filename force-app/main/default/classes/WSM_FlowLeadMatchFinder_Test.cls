@isTest
private class WSM_FlowLeadMatchFinder_Test {

    static Database.DMLOptions allowDupes() {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        return dml;
    }

    @isTest
    static void testFindMatches() {
        Account probeAcct = new Account(Name = 'WSM Match Probe Co');
        Database.insert(probeAcct, allowDupes());
        Contact probeCon = new Contact(FirstName = 'Mona', LastName = 'Matchprobe', Email = 'mona.matchprobe@wsmprobe.example.com', AccountId = probeAcct.Id);
        Database.insert(probeCon, allowDupes());
        Lead ld = new Lead(FirstName = 'Mona', LastName = 'Matchprobe', Company = 'WSM Match Probe Co', Email = 'mona.matchprobe@wsmprobe.example.com');
        Database.insert(ld, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper input = new WSM_FlowLeadMatchFinderInputWrapper();
        input.leadId = ld.Id;

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs =
            WSM_FlowLeadMatchFinder.findMatches(new List<WSM_FlowLeadMatchFinderInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        WSM_FlowLeadMatchFinderOutputWrapper o = outputs[0];
        System.assertNotEquals(null, o.matchedAccounts);
        System.assertNotEquals(null, o.matchedContacts);
        System.assertEquals(o.matchedAccounts.size(), o.accountMatchCount);
        System.assertEquals(o.matchedContacts.size(), o.contactMatchCount);
        System.assertEquals(o.accountMatchCount > 0, o.hasAccountMatches);
        System.assertEquals(o.contactMatchCount > 0, o.hasContactMatches);
    }

    @isTest
    static void testBulkAndInvalidInputs() {
        Lead ld = new Lead(FirstName = 'Solo', LastName = 'Nomatch', Company = 'WSM Zero Match Co 90210');
        Database.insert(ld, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper good = new WSM_FlowLeadMatchFinderInputWrapper();
        good.leadId = ld.Id;
        good.maxResults = 3;

        WSM_FlowLeadMatchFinderInputWrapper badId = new WSM_FlowLeadMatchFinderInputWrapper();
        badId.leadId = 'not-an-id';

        WSM_FlowLeadMatchFinderInputWrapper blank = new WSM_FlowLeadMatchFinderInputWrapper();
        blank.leadId = '';

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs = WSM_FlowLeadMatchFinder.findMatches(
            new List<WSM_FlowLeadMatchFinderInputWrapper>{ good, badId, blank });
        Test.stopTest();

        System.assertEquals(3, outputs.size());
        for (WSM_FlowLeadMatchFinderOutputWrapper o : outputs) {
            System.assertNotEquals(null, o.matchedAccounts);
            System.assertNotEquals(null, o.matchedContacts);
        }
        System.assertEquals(0, outputs[1].accountMatchCount);
        System.assertEquals(false, outputs[1].hasAccountMatches);
        System.assertEquals(0, outputs[2].contactMatchCount);
        System.assert(outputs[0].matchedAccounts.size() <= 3);
        System.assert(outputs[0].matchedContacts.size() <= 3);
    }
}
