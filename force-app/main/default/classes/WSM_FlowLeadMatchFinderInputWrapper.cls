public with sharing class WSM_FlowLeadMatchFinderInputWrapper {

    @InvocableVariable(required=true label='Lead Id' description='Id of the Lead to find conversion matches for.')
    public String leadId;

    @InvocableVariable(required=false label='Max Results' description='Maximum matches to return per object. Defaults to 5.')
    public Integer maxResults;
}
