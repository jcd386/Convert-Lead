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

    @isTest
    static void testPersonLeadMatchesPersonAccounts() {
        if (!personAccountsEnabled()) {
            return;
        }
        List<SObject> personRts = Database.query('SELECT Id FROM RecordType WHERE SobjectType = \'Account\' AND IsPersonType = true AND IsActive = true LIMIT 1');
        if (personRts.isEmpty()) {
            return;
        }
        SObject pa = Schema.getGlobalDescribe().get('Account').newSObject();
        pa.put('RecordTypeId', (Id) personRts[0].get('Id'));
        pa.put('FirstName', 'Match');
        pa.put('LastName', 'PersonProbe');
        pa.put('PersonEmail', 'match.personprobe@wsmpa.example.com');
        Database.insert(pa, allowDupes());

        Lead pl = new Lead(FirstName = 'Match', LastName = 'PersonProbe', Email = 'match.personprobe@wsmpa.example.com');
        Database.insert(pl, allowDupes());

        WSM_FlowLeadMatchFinderInputWrapper input = new WSM_FlowLeadMatchFinderInputWrapper();
        input.leadId = pl.Id;

        Test.startTest();
        List<WSM_FlowLeadMatchFinderOutputWrapper> outputs =
            WSM_FlowLeadMatchFinder.findMatches(new List<WSM_FlowLeadMatchFinderInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isPersonLead, 'Blank Company should flag a person lead');
        System.assertEquals(true, outputs[0].hasAccountMatches, 'Expected the existing Person Account to match');
        System.assert(outputs[0].matchedAccountsHtml.contains((String) pa.get('Id')), outputs[0].matchedAccountsHtml);
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
        System.assertEquals(o.hasAccountMatches, o.matchedAccountsHtml != null);
        System.assertEquals(o.hasContactMatches, o.matchedContactsHtml != null);
        if (o.matchedAccountsHtml != null) {
            System.assert(o.matchedAccountsHtml.contains('<a href="/'), o.matchedAccountsHtml);
        }
        System.assertEquals(o.accountMatchCount, o.accountOptions.size());
        System.assertEquals(o.contactMatchCount, o.contactOptions.size());
        for (Account shell : o.accountOptions) {
            System.assert(shell.Name.contains('<a href="/' + shell.AccountNumber + '"'), shell.Name);
        }
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
