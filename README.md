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
- **Match suggestions** — a second action, **Find Lead Conversion Matches**, runs your org's duplicate/matching rules against the Lead and returns existing Accounts and Contacts to convert into (with an exact name/email fallback that also covers orgs with no active rules), including ready-to-display HTML link lists so users can click through and review each match
- **Record types** — optional Account/Contact/Opportunity Record Type inputs (Id, DeveloperName, or label) set the record type after conversion; `Database.convertLead()` itself offers no record-type control. Uses dynamic field access so the package still deploys in orgs with no record types

## Inputs

| Input | Required | Description |
|-------|----------|-------------|
| Lead Id | Yes | Id of the Lead to convert |
| Converted Status Name | No | Lead Status to use. Leave blank to auto-select the first converted status that works for the lead. Case-insensitive |
| Do Not Create Opportunity | No | TRUE skips Opportunity creation. Defaults to FALSE (an Opportunity is created) |
| Existing Account Id | No | Convert into this Account. Blank creates a new Account |
| Existing Contact Id | No | Convert into this Contact (must belong to the Account). Blank creates a new Contact |
| Existing Opportunity Id | No | Convert into this Opportunity. Blank creates a new one unless Do Not Create Opportunity is TRUE |
| Person Account Id | No | Person Account orgs only — related person account for the conversion |
| New Owner Id | No | User or Queue to own the converted records. Blank keeps the Lead owner |
| Opportunity Name | No | Name for the new Opportunity. Blank uses the default (Account name) |
| Send Notification Email | No | TRUE sends the new-owner notification email. Defaults to FALSE |
| Overwrite Lead Source | No | TRUE overwrites the Contact Lead Source with the Lead's value. Defaults to FALSE |
| Account Name | No | Renames the Account after conversion (new or existing) |
| Contact First Name | No | Renames the Contact first name after conversion |
| Contact Last Name | No | Renames the Contact last name after conversion |
| Account Record Type | No | Record Type set on the Account after conversion — Id, DeveloperName, or label |
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
| Person Account Id | Related person account, when applicable |

## Find Lead Conversion Matches

The companion action replicates the standard convert screen's duplicate suggestions. Give it a Lead Id and it returns:

| Output | Description |
|--------|-------------|
| Matched Accounts | Existing Accounts matching the Lead (record collection) |
| Matched Contacts | Existing Contacts matching the Lead (record collection) |
| Account/Contact Match Count | Counts for display text |
| Has Account/Contact Matches | Booleans for component visibility |
| Matched Accounts/Contacts HTML | Rich-text link lists (record name links to the record, plus city/website or account/email context) — drop straight into a Display Text component |

Matching runs `Datacloud.FindDuplicates` against your org's active duplicate rules using an in-memory Account (from the Lead's Company/Phone) and Contact (from the Lead's name/email/phone). When rules are missing or find nothing, an exact-match fallback fills in: Account by name, Contact by email then by name. `Max Results` caps each list (default 5).

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

## Example: Full Convert-Screen Replacement

`examples/` contains a ready-to-use Screen Flow (`WSM_SCR_Lead_Convert_Lead`) plus a Lead quick action that together replace the out-of-the-box convert screen: duplicate-match suggestions with clickable review links, one-click pick, and "N possible matches found" hints, converted-status picker with auto-detect default, new-vs-existing Account/Contact/Opportunity with searchable lookups, inline editing of the new Account/Contact/Opportunity names, owner reassignment, notification email, and lead source overwrite — with a success screen linking the converted records and an error screen that lets the user fix inputs and retry. Existing-Contact and existing-Opportunity choices are gated behind choosing an existing Account first, matching the platform rule that they must belong to it.

```
sf project deploy start -d examples -o your-org-alias
```

Then add the **Convert Lead (WSM)** quick action to your Lead page layout's Salesforce Mobile and Lightning Experience Actions section.

Two portability notes baked into the example: screen choice references can return the choice label instead of its stored value depending on runtime, so every static choice uses identical label/value strings — keep that pattern if you edit them. The Record Owner picker resolves the selection to a User Id either way (accepts an Id directly or looks it up by name).

## Test Notes

The test class discovers a working converted status by trial conversion, so it passes regardless of how your org renamed or restricted Lead Status values. Test data is inserted with duplicate rules bypassed (`DuplicateRuleHeader.allowSave`). Orgs with custom required fields or validation rules on Lead, Account, or Contact may still need those satisfied for tests to run.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `WSM_FlowLeadConverter` | Apex Class | Invocable action |
| `WSM_FlowLeadConverterInputWrapper` | Apex Class | Input variables |
| `WSM_FlowLeadConverterOutputWrapper` | Apex Class | Output variables |
| `WSM_FlowLeadConverter_Test` | Apex Class | Test coverage |
