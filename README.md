# Convert Lead

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/src/main/webapp/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/app/githubdeploy/jcd386/Convert-Lead?ref=main)

Flow-invocable Apex action to convert Salesforce Leads. Exposes the full `Database.convertLead()` capability to Flows and Agentforce — convert into new or existing Accounts, Contacts, and Opportunities, with per-record success/error outputs that never fault your flow.

## Features

- **Bulk-safe** — one output per input, always in the same order, so record-triggered flows get the right results even when some conversions fail
- **Never faults your flow** — partial-success conversion (`allOrNone=false`); each output carries `isSuccess` and `errorMessage` so you can branch on failures
- **Auto-detects the converted status** — leave `Converted Status Name` blank and the action finds a converted status that works for the lead, even in orgs where record type business processes restrict which converted statuses are valid
- **Case-insensitive status matching** — "converted" and "Converted" both work; bad values return the list of valid ones in the error message
- **Convert into existing records** — optional Account, Contact, Opportunity, and Person Account targets
- **Full conversion options** — new owner, opportunity name, owner notification email, overwrite lead source
- **Blank-tolerant inputs** — empty strings from Flow are treated as unset instead of throwing invalid-ID errors

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

## Outputs

| Output | Description |
|--------|-------------|
| Success | TRUE if the Lead converted |
| Error Message | Populated when Success is FALSE |
| Account Id | Account the Lead was converted into |
| Contact Id | Contact the Lead was converted into |
| Opportunity Id | Opportunity created or converted into (null when skipped) |
| Person Account Id | Related person account, when applicable |

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

`examples/` contains a ready-to-use Screen Flow (`WSM_SCR_Lead_Convert_Lead`) plus a Lead quick action that together replace the out-of-the-box convert screen: converted-status picker with auto-detect default, new-vs-existing Account/Contact/Opportunity with searchable lookups, opportunity naming, owner reassignment, notification email, and lead source overwrite — with a success screen linking the converted records and an error screen that lets the user fix inputs and retry.

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
