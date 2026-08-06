@isTest
private class WSM_FlowLeadConverter_Test {

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
        System.assert(outputs[0].errorMessage.contains('Definitely Not A Real Status'));
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
        System.assert(outputs[0].warningMessage.contains('record type'), outputs[0].warningMessage);
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
}
