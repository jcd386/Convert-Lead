@isTest
private class WSM_FlowLeadConverter_Test {

    // Person Account fields only exist when Person Accounts are enabled, so PA
    // assertions are skipped (not failed) in orgs without them. Every PA field
    // reference below is dynamic so this class compiles in both org shapes.
    static Boolean personAccountsEnabled() {
        return Schema.SObjectType.Account.fields.getMap().containsKey('ispersonaccount');
    }

    static Database.DMLOptions allowDupes() {
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        return dml;
    }

    static Lead makeLead(String lastName, String company) {
        Lead l = new Lead(FirstName = 'Test', LastName = lastName, Company = company);
        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        Database.insert(l, dml);
        return l;
    }

    // An org-wide converted status can still be invalid for the default lead
    // record type's business process, so discover one by trial conversion.
    // Returns null if no converted status works in this org.
    static String findWorkingConvertedStatus() {
        Lead probe = makeLead('Probe', 'WSM Probe Co');
        for (LeadStatus ls : [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            Database.LeadConvert lc = new Database.LeadConvert();
            lc.setLeadId(probe.Id);
            lc.setConvertedStatus(ls.MasterLabel);
            lc.setDoNotCreateOpportunity(true);
            Database.LeadConvertResult res = Database.convertLead(lc, false);
            if (res.isSuccess()) {
                return ls.MasterLabel;
            }
        }
        return null;
    }

    @isTest
    static void testConvertIntoExistingAccountAndContact() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        Account acct = new Account(Name = 'WSM Convert Test Account');
        Database.insert(acct, dml);
        Contact con = new Contact(FirstName = 'Test', LastName = 'Existing', AccountId = acct.Id);
        Database.insert(con, dml);
        Lead l = makeLead('Existing', 'WSM Convert Test Account');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.accountId = acct.Id;
        input.contactId = con.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertEquals(acct.Id, outputs[0].accountId);
        System.assertEquals(con.Id, outputs[0].contactId);
        System.assertEquals(null, outputs[0].opportunityId);
    }

    @isTest
    static void testConvertCreatesOpportunity() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Lead l = makeLead('OppPath', 'WSM Opp Path Co');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = false;
        input.opportunityName = 'WSM Test Converted Opp';
        input.ConvertedStatusName = workingStatus;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertNotEquals(null, outputs[0].accountId);
        System.assertNotEquals(null, outputs[0].contactId);
        System.assertNotEquals(null, outputs[0].opportunityId);
    }

    @isTest
    static void testBlankStatusAutoSelects() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Lead l = makeLead('BlankStatus', 'WSM Blank Status Co');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(1, outputs.size());
        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertNotEquals(null, outputs[0].accountId);
    }

    @isTest
    static void testBadStatusReturnsAlignedError() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Lead good = makeLead('Aligned', 'WSM Aligned Co');
        Lead bad = makeLead('BadStatus', 'WSM Bad Status Co');

        WSM_FlowLeadConverterInputWrapper badInput = new WSM_FlowLeadConverterInputWrapper();
        badInput.leadId = bad.Id;
        badInput.doNotCreateOpp = true;
        badInput.ConvertedStatusName = 'Definitely Not A Real Status';

        WSM_FlowLeadConverterInputWrapper goodInput = new WSM_FlowLeadConverterInputWrapper();
        goodInput.leadId = good.Id;
        goodInput.doNotCreateOpp = true;
        goodInput.ConvertedStatusName = workingStatus;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ badInput, goodInput });
        Test.stopTest();

        System.assertEquals(2, outputs.size());
        System.assertEquals(false, outputs[0].isSuccess);
        System.assert(outputs[0].errorMessage != null && outputs[0].errorMessage.contains('Definitely Not A Real Status'));
        System.assertEquals(true, outputs[1].isSuccess, 'Convert failed: ' + outputs[1].errorMessage);
        System.assertNotEquals(null, outputs[1].accountId);
    }

    @isTest
    static void testInvalidLeadIdReturnsError() {
        WSM_FlowLeadConverterInputWrapper badFormat = new WSM_FlowLeadConverterInputWrapper();
        badFormat.leadId = 'not-an-id';
        badFormat.doNotCreateOpp = true;

        WSM_FlowLeadConverterInputWrapper blank = new WSM_FlowLeadConverterInputWrapper();
        blank.leadId = '';
        blank.doNotCreateOpp = true;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ badFormat, blank });
        Test.stopTest();

        System.assertEquals(2, outputs.size());
        System.assertEquals(false, outputs[0].isSuccess);
        System.assertNotEquals(null, outputs[0].errorMessage);
        System.assertEquals(false, outputs[1].isSuccess);
        System.assertNotEquals(null, outputs[1].errorMessage);
    }

    @isTest
    static void testInlineRenames() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Lead l = makeLead('RenameMe', 'WSM Rename Co');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountName = 'WSM Renamed Account';
        input.contactFirstName = 'Renny';
        input.contactLastName = 'Named';

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertEquals(null, outputs[0].warningMessage, 'Rename warning: ' + outputs[0].warningMessage);
        Account acct = [SELECT Name FROM Account WHERE Id = :outputs[0].accountId];
        System.assertEquals('WSM Renamed Account', acct.Name);
        Contact con = [SELECT FirstName, LastName FROM Contact WHERE Id = :outputs[0].contactId];
        System.assertEquals('Renny', con.FirstName);
        System.assertEquals('Named', con.LastName);
    }

    @isTest
    static void testExistingOpportunityRename() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        Database.DMLOptions dml = new Database.DMLOptions();
        dml.DuplicateRuleHeader.allowSave = true;
        Account acct = new Account(Name = 'WSM Opp Rename Account');
        Database.insert(acct, dml);
        Opportunity opp = new Opportunity(Name = 'Old Opp Name', AccountId = acct.Id, StageName = 'Prospecting', CloseDate = Date.today().addDays(30));
        Database.insert(opp, dml);
        Lead l = makeLead('OppRename', 'WSM Opp Rename Account');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = false;
        input.accountId = acct.Id;
        input.opportunityId = opp.Id;
        input.opportunityName = 'New Opp Name';
        input.ConvertedStatusName = workingStatus;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertEquals(opp.Id, outputs[0].opportunityId);
        Opportunity renamed = [SELECT Name FROM Opportunity WHERE Id = :opp.Id];
        System.assertEquals('New Opp Name', renamed.Name);
    }

    @isTest
    static void testRecordTypeAssignment() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        List<RecordType> acctRts = [SELECT Id, DeveloperName FROM RecordType WHERE SobjectType = 'Account' AND IsActive = true LIMIT 1];

        Lead l = makeLead('RtPath', 'WSM Record Type Co');
        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountRecordType = acctRts.isEmpty() ? 'No Such Record Type XYZ' : acctRts[0].DeveloperName;

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        if (acctRts.isEmpty()) {
            System.assertNotEquals(null, outputs[0].warningMessage);
        } else {
            SObject acct = Database.query('SELECT RecordTypeId FROM Account WHERE Id = \'' + outputs[0].accountId + '\'')[0];
            System.assertEquals(acctRts[0].Id, (Id) acct.get('RecordTypeId'));
            System.assertEquals(null, outputs[0].warningMessage, 'Warning: ' + outputs[0].warningMessage);
        }
    }

    @isTest
    static void testBadRecordTypeWarns() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        Lead l = makeLead('RtWarn', 'WSM Record Type Warn Co');
        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountRecordType = 'Definitely No Such Record Type';

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertNotEquals(null, outputs[0].warningMessage);
        System.assert(outputs[0].warningMessage != null && outputs[0].warningMessage.contains('record type'), 'warning: ' + outputs[0].warningMessage);
    }

    @isTest
    static void testPersonLeadConvertsToPersonAccount() {
        if (!personAccountsEnabled()) {
            return;
        }
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        // No Company = person lead. Lead.Company is nillable only in PA orgs.
        Lead pl = new Lead(FirstName = 'Pat', LastName = 'PersonTest');
        Database.insert(pl, allowDupes());

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = pl.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountName = 'Should Not Apply To A Person Account';
        input.contactFirstName = 'Patricia';

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertEquals(true, outputs[0].isPersonAccount, 'Expected a Person Account');
        System.assertNotEquals(null, outputs[0].warningMessage, 'Expected an Account Name warning');
        System.assert(outputs[0].warningMessage != null && outputs[0].warningMessage.contains('Person Account'), 'warning: ' + outputs[0].warningMessage);
        SObject con = Database.query('SELECT FirstName FROM Contact WHERE Id = \'' + outputs[0].contactId + '\'')[0];
        System.assertEquals('Patricia', (String) con.get('FirstName'), 'Contact rename should work on a Person Account');
    }

    @isTest
    static void testConvertIntoExistingPersonAccountResolvesContact() {
        if (!personAccountsEnabled()) {
            return;
        }
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        List<SObject> personRts = Database.query('SELECT Id FROM RecordType WHERE SobjectType = \'Account\' AND IsPersonType = true AND IsActive = true LIMIT 1');
        if (personRts.isEmpty()) {
            return;
        }

        SObject pa = Schema.getGlobalDescribe().get('Account').newSObject();
        pa.put('RecordTypeId', (Id) personRts[0].get('Id'));
        pa.put('FirstName', 'Existing');
        pa.put('LastName', 'PersonAcct');
        Database.insert(pa, allowDupes());
        Id paId = (Id) pa.get('Id');

        Lead pl = new Lead(FirstName = 'Existing', LastName = 'PersonAcct');
        Database.insert(pl, allowDupes());

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = pl.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountId = paId;
        // Deliberately no contactId: the action must resolve the person Contact.

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'Convert failed: ' + outputs[0].errorMessage);
        System.assertEquals(paId, outputs[0].accountId);
        System.assertEquals(true, outputs[0].isPersonAccount);
        System.assertNotEquals(null, outputs[0].contactId, 'Person Contact should have been resolved');
    }

    @isTest
    static void testBulkConvertNewAccounts() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }

        List<WSM_FlowLeadConverterInputWrapper> inputs = new List<WSM_FlowLeadConverterInputWrapper>();
        for (Integer i = 0; i < 5; i++) {
            Lead l = makeLead('Bulk' + i, 'WSM Bulk Co ' + i);
            WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
            input.leadId = l.Id;
            input.doNotCreateOpp = true;
            inputs.add(input);
        }

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs = WSM_FlowLeadConverter.convertLead(inputs);
        Test.stopTest();

        System.assertEquals(5, outputs.size());
        for (WSM_FlowLeadConverterOutputWrapper o : outputs) {
            System.assertEquals(true, o.isSuccess, 'Convert failed: ' + o.errorMessage);
            System.assertNotEquals(null, o.accountId);
            System.assertNotEquals(null, o.contactId);
        }
    }

    @isTest
    static void testChunkingConvertsEveryRecord() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        List<WSM_FlowLeadConverterInputWrapper> inputs = new List<WSM_FlowLeadConverterInputWrapper>();
        for (Integer i = 0; i < 5; i++) {
            Lead l = makeLead('Chunk' + i, 'WSM Chunk Co ' + i);
            WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
            input.leadId = l.Id;
            input.doNotCreateOpp = true;
            input.ConvertedStatusName = workingStatus;
            inputs.add(input);
        }

        Test.startTest();
        // Force several chunks so the boundary logic is exercised without
        // creating the 100+ records the real threshold would need.
        WSM_FlowLeadConverter.chunkSize = 2;
        List<WSM_FlowLeadConverterOutputWrapper> outputs = WSM_FlowLeadConverter.convertLead(inputs);
        Test.stopTest();

        System.assertEquals(5, outputs.size(), 'every input still gets an output');
        for (Integer i = 0; i < outputs.size(); i++) {
            System.assertEquals(true, outputs[i].isSuccess, 'row ' + i + ': ' + outputs[i].errorMessage);
            System.assertNotEquals(null, outputs[i].accountId, 'row ' + i + ' should have an Account');
        }
    }

    @isTest
    static void testNonStatusFailureIsNotRetried() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        // How many attempts SHOULD a retry-eligible row take? Exactly enough to get
        // past any statuses this record type rejects, and not one more. Computing it
        // keeps the assertion true in any org, whatever its converted statuses are.
        List<String> ordered = new List<String>();
        for (LeadStatus ls : [SELECT MasterLabel FROM LeadStatus WHERE IsConverted = true ORDER BY SortOrder]) {
            ordered.add(ls.MasterLabel);
        }
        Integer expectedAttempts = ordered.indexOf(workingStatus) + 1;

        Lead l = makeLead('NoRetry', 'WSM No Retry Co');
        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        // Blank status = auto-detect, so this row is retry-eligible...
        input.accountId = '001000000000000AAA';  // ...but the failure is not status related

        Test.startTest();
        Integer before = Limits.getDmlStatements();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Integer used = Limits.getDmlStatements() - before;
        Test.stopTest();

        System.assertEquals(false, outputs[0].isSuccess);
        System.assertNotEquals(null, outputs[0].errorMessage);
        System.assert(!outputs[0].errorMessage.contains('convertedStatus'),
            'the real cause should be reported, not a status error: ' + outputs[0].errorMessage);
        System.assertEquals(expectedAttempts, used,
            'a non-status failure must stop retrying once status is no longer the problem');
    }

    @isTest
    static void testConflictingRenamesWarnBothRows() {
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        Database.DMLOptions dml = allowDupes();
        Account shared = new Account(Name = 'WSM Shared Rename Target');
        Database.insert(shared, dml);
        Lead a = makeLead('ConflictA', 'WSM Shared Rename Target');
        Lead b = makeLead('ConflictB', 'WSM Shared Rename Target');

        WSM_FlowLeadConverterInputWrapper ia = new WSM_FlowLeadConverterInputWrapper();
        ia.leadId = a.Id; ia.doNotCreateOpp = true; ia.ConvertedStatusName = workingStatus;
        ia.accountId = shared.Id; ia.accountName = 'Name From A';
        WSM_FlowLeadConverterInputWrapper ib = new WSM_FlowLeadConverterInputWrapper();
        ib.leadId = b.Id; ib.doNotCreateOpp = true; ib.ConvertedStatusName = workingStatus;
        ib.accountId = shared.Id; ib.accountName = 'Name From B';

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ ia, ib });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'error: ' + outputs[0].errorMessage);
        System.assertEquals(true, outputs[1].isSuccess, 'error: ' + outputs[1].errorMessage);
        System.assertNotEquals(null, outputs[0].warningMessage, 'first row should learn its value was contested');
        System.assertNotEquals(null, outputs[1].warningMessage, 'second row should learn its value was ignored');
        SObject acct = Database.query('SELECT Name FROM Account WHERE Id = \'' + shared.Id + '\'')[0];
        System.assertEquals('Name From A', (String) acct.get('Name'), 'first value wins deterministically');
    }

    @isTest
    static void testWrongObjectIdGivesAClearError() {
        Database.DMLOptions dml = allowDupes();
        Account acct = new Account(Name = 'WSM Wrong Id Co');
        Database.insert(acct, dml);
        Lead l = makeLead('WrongId', 'WSM Wrong Id Co');

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        input.contactId = acct.Id;  // an Account Id where a Contact is expected

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(false, outputs[0].isSuccess);
        System.assert(outputs[0].errorMessage != null && outputs[0].errorMessage.contains('Existing Contact Id'), 'error: ' + outputs[0].errorMessage);
        System.assert(outputs[0].errorMessage != null && outputs[0].errorMessage.contains('Account'), outputs[0].errorMessage);
    }

    @isTest
    static void testPersonAccountIgnoresSuppliedContactId() {
        if (!personAccountsEnabled()) {
            return;
        }
        String workingStatus = findWorkingConvertedStatus();
        if (workingStatus == null) {
            return;
        }
        List<SObject> personRts = Database.query('SELECT Id FROM RecordType WHERE SobjectType = \'Account\' AND IsPersonType = true AND IsActive = true LIMIT 1');
        if (personRts.isEmpty()) {
            return;
        }
        SObject pa = Schema.getGlobalDescribe().get('Account').newSObject();
        pa.put('RecordTypeId', (Id) personRts[0].get('Id'));
        pa.put('FirstName', 'Ignore');
        pa.put('LastName', 'ContactId');
        Database.insert(pa, allowDupes());
        Id paId = (Id) pa.get('Id');
        Id personContactId = (Id) Database.query('SELECT PersonContactId FROM Account WHERE Id = \'' + paId + '\'')[0].get('PersonContactId');

        Lead l = new Lead(FirstName = 'Ignore', LastName = 'ContactId');
        Database.insert(l, allowDupes());

        WSM_FlowLeadConverterInputWrapper input = new WSM_FlowLeadConverterInputWrapper();
        input.leadId = l.Id;
        input.doNotCreateOpp = true;
        input.ConvertedStatusName = workingStatus;
        input.accountId = paId;
        input.contactId = personContactId;  // documented as invalid for a person account

        Test.startTest();
        List<WSM_FlowLeadConverterOutputWrapper> outputs =
            WSM_FlowLeadConverter.convertLead(new List<WSM_FlowLeadConverterInputWrapper>{ input });
        Test.stopTest();

        System.assertEquals(true, outputs[0].isSuccess, 'error: ' + outputs[0].errorMessage);
        System.assertEquals(paId, outputs[0].accountId);
        System.assertNotEquals(null, outputs[0].warningMessage, 'caller should be told the Contact Id was ignored');
        System.assert(outputs[0].warningMessage != null && outputs[0].warningMessage.contains('Person Account'), 'warning: ' + outputs[0].warningMessage);
    }

}
