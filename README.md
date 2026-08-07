# Convert Lead

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/src/main/webapp/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/app/githubdeploy/jcd386/Convert-Lead?ref=main)

Flow-invocable Apex actions to convert Salesforce Leads. Exposes the full `Database.convertLead()` capability to Flows and Agentforce — convert into new or existing Accounts, Contacts, and Opportunities, with duplicate-rule match suggestions, inline renames, and per-record success/error outputs that never fault your flow.

## Features

- **Bulk-safe** — one output per input, always in the same order, so record-triggered flows get the right results even when some conversions fail
- **Never faults your flow** — partial-success conversion (`allOrNone=false`); each output carries `isSuccess` and `errorMessage` so you can branch on failures
- **Auto-detects the converted status** — leave `Converted Status Name` blank and the action finds a converted status that works for the lead, even in orgs where record type business processes restrict which converted statuses are valid
- **Case-insensitive status matching** — "converted" and "Converted" both work; bad values return the list of valid ones in the error message
- **Convert into existing records** — optional Account, Contact, Opportunity, and Person Account targets
- **Full conversion options** — new owner, opportunity name, owner notification email, overwrite lead source
- **Blank-tolerant inputs** — empty strings from Flow are treated as unset instead of throwing invalid-ID errors
- **Duplicate-rule parity** — alert-mode duplicate rules block `Database.convertLead()` in the API context even though the standard convert screen saves through them; this action restores that parity via `DuplicateRuleHeader.allowSave` (block-mode rules still block)
- **Inline renames** — optional Account Name, Contact First/Last Name, and Opportunity Name inputs rename the records right after conversion, like the standard convert screen's editable fields
- **Match suggestions** — a second action, **Find Lead Conversion Matches**, runs your org's own duplicate/matching rules against the Lead and returns the existing Accounts and Contacts they match, including ready-to-display HTML link lists so users can click through and review each match before picking one
- **Record types** — optional Account/Contact/Opportunity Record Type inputs (Id, DeveloperName, or label) set the record type after conversion; `Database.convertLead()` itself offers no record-type control. Uses dynamic field access so the package still deploys in orgs with no record types
- **Person Account aware, without requiring Person Accounts** — a Lead with no Company converts to a Person Account (platform behavior); this action detects the result, resolves a Person Account's person Contact for you, and redirects the Account Name rename to the person's name fields. Every Person Account field reference is dynamic and runtime-gated, so the package installs and runs identically in orgs **with or without** Person Accounts enabled

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| Lead Id | Yes | Id of the Lead to convert |
| Converted Status Name | No | Lead Status to use. Leave blank to auto-select the first converted status that works for the lead. Case-insensitive |
| Do Not Create Opportunity | No | TRUE skips Opportunity creation. Defaults to FALSE (an Opportunity is created) |
| Existing Account Id | No | Convert into this Account. Blank creates a new Account |
| Existing Contact Id | No | Convert into this Contact (must belong to the Account). Blank creates a new Contact |
| Existing Opportunity Id | No | Convert into this Opportunity. Blank creates a new one unless Do Not Create Opportunity is TRUE |
| Person Account Id | No | Maps to `setRelatedPersonAccountId`, which the platform only accepts in orgs with **Contacts to Multiple Accounts** enabled. To convert into an existing Person Account without it, just pass the Person Account's Id as **Existing Account Id** — the action resolves the person Contact automatically |
| New Owner Id | No | User or Queue to own the converted records. Blank keeps the Lead owner |
| Opportunity Name | No | Name for the new Opportunity. Blank uses the default (Account name) |
| Send Notification Email | No | TRUE sends the new-owner notification email. Defaults to FALSE |
| Overwrite Lead Source | No | Only applies with an existing Contact — TRUE replaces that Contact's Lead Source with the Lead's value. A new Contact inherits it automatically. Defaults to FALSE |
| Account Name | No | Renames the Account after conversion (new or existing) |
| Contact First Name | No | Renames the Contact first name after conversion |
| Contact Last Name | No | Renames the Contact last name after conversion |
| Account Record Type | No | Record Type set on the Account after conversion — Id, DeveloperName, or label. Person/business type mismatches are caught with a warning instead of a platform error |
| Contact Record Type | No | Record Type set on the Contact after conversion — Id, DeveloperName, or label |
| Opportunity Record Type | No | Record Type set on the Opportunity after conversion — Id, DeveloperName, or label |

## Outputs

| Output | Description |
|--------|-------------|
| Success | TRUE if the Lead converted |
| Error Message | Populated when Success is FALSE |
| Warning Message | Populated when the Lead converted but a post-conversion rename failed |
| Account Id | Account the Lead was converted into |
| Contact Id | Contact the Lead was converted into |
| Opportunity Id | Opportunity created or converted into (null when skipped) |
| Person Account Id | Populated only when converting into an existing person account via the Person Account Id input |
| Is Person Account | TRUE when the converted Account is a Person Account. Always FALSE in orgs without Person Accounts |

## Find Lead Conversion Matches

The companion action replicates the standard convert screen's duplicate suggestions. Give it a Lead Id and it returns:

| Output | Description |
|--------|-------------|
| Matched Accounts | Existing Accounts matching the Lead (record collection) |
| Matched Contacts | Existing Contacts matching the Lead (record collection) |
| Account/Contact Match Count | Counts for display text |
| Has Account/Contact Matches | Booleans for component visibility |
| Matched Accounts/Contacts HTML | Rich-text link lists (record name links to the record, plus city/website or account/email context) — drop straight into a Display Text component |
| Is Person Lead | TRUE when the Lead has no Company, so it converts to a Person Account |
| Account/Contact Choice Options | Option-shell record collections for radio/picklist collection choice sets: display the `Name` field (a clickable link label with context) and use `AccountNumber` as the value (the matched record Id). Because the href embeds the Id, flows can recover the exact Id from the label with `MID(label, FIND("href=\"/001", label) + 7, 18)` in runtimes that return choice labels instead of values |

Matching runs `Datacloud.FindDuplicates` against your org's **active duplicate rules**, using throwaway in-memory records shaped from the Lead. Those records carry the same fields lead conversion itself maps across — Company, Phone, Website and the address on the Account side; name, email, phone, mobile, title and the address on the Contact side — so your matching rules have everything they key on. (The Standard Account Matching Rule, for one, needs address data and will not match on name alone.) Nothing is ever inserted; the action only reads. `Max Results` caps each list (default 5).

Results are filtered to the object being searched. Duplicate rules can span objects — the standard Contact rule also matches Contacts against Leads — so an unfiltered search hands back Lead Ids, including the Lead you are converting.

Suggestions come from your duplicate rules and nothing else. That is deliberate: matching belongs where admins already configure it, in Setup, so the action never imposes its own opinion about what "similar" means. If a lead you expect to match returns nothing, the rule didn't match it — for example, the Standard Account Duplicate Rule needs address data, so an identical Account **name** alone won't match. Tune the matching rule, or build the matching you want with Get Records elements and pass the result to **Convert Lead** directly.

A Lead with no Company (a person lead) is left out of the account pass entirely, since there is no account name to match on. Contact matching still runs. Note that Person Accounts are matched by the **Standard Person Account Duplicate Rule**, which is inactive in a new org — until you activate it (and its matching rule) in Setup, person leads return no suggestions.

Bulk-safe: whatever the batch size, the action uses a constant handful of queries — one for the Leads, one duplicate-rule call per object, and one lookup per object to load the matched records.

## Person Accounts

In a Person Account org, a Lead with a **blank Company** converts into a Person Account — that part is platform behavior, and this action passes straight through to it. What the action adds on top:

- **Detects the result.** `Database.convertLead()` gives you no signal that it produced a Person Account (`getRelatedPersonAccountId()` stays null for newly created ones), so the action queries it back and returns **Is Person Account**.
- **Resolves the person Contact.** Converting into an existing Person Account requires its person Contact as well as the account. Pass just the Person Account Id as **Existing Account Id** and the action fills in `PersonContactId` for you.
- **Redirects the Account rename.** `Account.Name` is read-only on a Person Account (it is derived from the person's first/last name), so an **Account Name** input there returns a clear warning telling you to use **Contact First Name / Contact Last Name** instead — which do work, and update the account's name.
- **Validates record types.** A Person Account needs a person-type record type and a business account needs a business one; a mismatch is caught with an explanatory warning rather than a raw platform error.

### It does not require Person Accounts

Person Account fields (`IsPersonAccount`, `Account.FirstName`, `PersonContactId`, `RecordType.IsPersonType`) **do not exist** in orgs without Person Accounts — a static Apex or SOQL reference to any of them fails to compile there and would block the whole package from installing. Every such reference in this package is therefore dynamic (`sobject.get`/`put`, `Database.query`) behind a runtime existence check, and the Person Account logic simply never runs where the feature is off. The package is verified deploying and passing the full test suite in both a Person-Account org and a non-Person-Account org.

If you build your own screen for this, note that `Lead.Company` is nillable **only** in Person Account orgs — it is required otherwise — so "Company is blank" is a person-lead test that needs no Person Account field reference and therefore works in any org.

## Why the status auto-detect matters

`Database.convertLead()` requires a converted Lead Status, but the valid value varies org to org — and it gets worse: if your Lead record types use business processes, an org-wide converted status can still be **invalid for a specific lead's record type**. This action handles both cases. Pass a status name if you want control; leave it blank and the action retries across every converted status in the org until one works for that lead.

## Installation

### Option A: One-Click Deploy

Click the "Deploy to Salesforce" button above.

### Option B: SFDX CLI

```
git clone https://github.com/jcd386/Convert-Lead.git
cd Convert-Lead
sf project deploy start -d force-app -o your-org-alias
```

## Usage in Flow

1. Add an **Action** element to your flow
2. Search for **Convert Lead**
3. Set **Lead Id** (and any optional inputs)
4. After the action, branch on **Success** — when FALSE, **Error Message** explains why

## Test Notes

The test class discovers a working converted status by trial conversion, so it passes regardless of how your org renamed or restricted Lead Status values. Person Account assertions are skipped (not failed) in orgs without Person Accounts, and every Person Account reference in the tests is dynamic so they compile in both org shapes. Test data is inserted with duplicate rules bypassed (`DuplicateRuleHeader.allowSave`). Orgs with custom required fields or validation rules on Lead, Account, or Contact may still need those satisfied for tests to run.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `WSM_FlowLeadConverter` | Apex Class | **Convert Lead** invocable action |
| `WSM_FlowLeadConverterInputWrapper` | Apex Class | Convert Lead input variables |
| `WSM_FlowLeadConverterOutputWrapper` | Apex Class | Convert Lead output variables |
| `WSM_FlowLeadConverter_Test` | Apex Class | Convert Lead test coverage |
| `WSM_FlowLeadMatchFinder` | Apex Class | **Find Lead Conversion Matches** invocable action |
| `WSM_FlowLeadMatchFinderInputWrapper` | Apex Class | Match finder input variables |
| `WSM_FlowLeadMatchFinderOutputWrapper` | Apex Class | Match finder output variables |
| `WSM_FlowLeadMatchFinder_Test` | Apex Class | Match finder test coverage |

Apex only — no flows, layouts, or components are installed, so the actions drop into whatever UI you already have.
