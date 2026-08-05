public with sharing class WSM_FlowLeadConverterInputWrapper {

    @InvocableVariable(required=true label='Lead Id' description='Id of the Lead to convert.')
    public String leadId;

    @InvocableVariable(required=false label='Converted Status Name' description='Lead Status to use for conversion. Case-insensitive. Leave blank to auto-select the first converted status that works for the lead.')
    public String ConvertedStatusName;

    @InvocableVariable(required=false label='Do Not Create Opportunity' description='TRUE skips Opportunity creation. Defaults to FALSE (an Opportunity is created).')
    public Boolean doNotCreateOpp;

    @InvocableVariable(required=false label='Existing Account Id' description='Convert into this Account. Leave blank to create a new Account.')
    public String accountId;

    @InvocableVariable(required=false label='Existing Contact Id' description='Convert into this Contact. Must belong to the specified Account. Leave blank to create a new Contact.')
    public String contactId;

    @InvocableVariable(required=false label='Existing Opportunity Id' description='Convert into this Opportunity. Leave blank to create a new one unless Do Not Create Opportunity is TRUE.')
    public String opportunityId;

    @InvocableVariable(required=false label='Person Account Id' description='Person Account orgs only: related person account for the conversion.')
    public String personAccountId;

    @InvocableVariable(required=false label='New Owner Id' description='User or Queue to own the converted records. Leave blank to keep the Lead owner.')
    public String ownerId;

    @InvocableVariable(required=false label='Opportunity Name' description='Name for the new Opportunity. Leave blank for the default (Account name).')
    public String opportunityName;

    @InvocableVariable(required=false label='Send Notification Email' description='TRUE sends the new-owner notification email. Defaults to FALSE.')
    public Boolean sendNotificationEmail;

    @InvocableVariable(required=false label='Overwrite Lead Source' description='TRUE overwrites the Contact LeadSource with the Lead value. Defaults to FALSE.')
    public Boolean overwriteLeadSource;
}
