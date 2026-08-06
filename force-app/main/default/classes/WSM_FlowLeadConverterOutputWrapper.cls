public with sharing class WSM_FlowLeadConverterOutputWrapper {

    @InvocableVariable(label='Success' description='TRUE if the Lead converted successfully.')
    public Boolean isSuccess;

    @InvocableVariable(label='Error Message' description='Populated when Success is FALSE.')
    public String errorMessage;

    @InvocableVariable(label='Warning Message' description='Populated when the Lead converted but a post-conversion rename failed.')
    public String warningMessage;

    @InvocableVariable(label='Account Id')
    public String accountId;

    @InvocableVariable(label='Contact Id')
    public String contactId;

    @InvocableVariable(label='Opportunity Id')
    public String opportunityId;

    @InvocableVariable(label='Person Account Id')
    public String personAccountId;
}
