public with sharing class WSM_FlowLeadMatchFinderOutputWrapper {

    @InvocableVariable(label='Matched Accounts' description='Existing Accounts that match the Lead, per the org duplicate rules (or exact-name fallback).')
    public List<Account> matchedAccounts;

    @InvocableVariable(label='Matched Contacts' description='Existing Contacts that match the Lead, per the org duplicate rules (or email/name fallback).')
    public List<Contact> matchedContacts;

    @InvocableVariable(label='Account Match Count')
    public Integer accountMatchCount;

    @InvocableVariable(label='Contact Match Count')
    public Integer contactMatchCount;

    @InvocableVariable(label='Has Account Matches')
    public Boolean hasAccountMatches;

    @InvocableVariable(label='Has Contact Matches')
    public Boolean hasContactMatches;

    @InvocableVariable(label='Matched Accounts HTML' description='Ready-to-display rich text: one line per matched Account with a clickable link to the record.')
    public String matchedAccountsHtml;

    @InvocableVariable(label='Matched Contacts HTML' description='Ready-to-display rich text: one line per matched Contact with a clickable link to the record.')
    public String matchedContactsHtml;

    @InvocableVariable(label='Account Choice Options' description='For radio/picklist collection choice sets: display the Name field (a clickable link label) and use AccountNumber as the value (the matched Account Id).')
    public List<Account> accountOptions;

    @InvocableVariable(label='Contact Choice Options' description='For radio/picklist collection choice sets: display the Name field (a clickable link label) and use AccountNumber as the value (the matched Contact Id).')
    public List<Account> contactOptions;

    @InvocableVariable(label='Is Person Lead' description='TRUE when the Lead has no Company, meaning it converts to a Person Account. Always FALSE in orgs without Person Accounts, where Company is required.')
    public Boolean isPersonLead;
}
