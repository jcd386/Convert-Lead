# Convert Lead

[![Deploy to Salesforce](https://raw.githubusercontent.com/afawcett/githubsfdeploy/master/src/main/webapp/resources/img/deploy.png)](https://githubsfdeploy.herokuapp.com/app/githubdeploy/jcd386/Convert-Lead?ref=main)

Flow-invocable Apex action to convert Salesforce Leads. Exposes the full `Database.convertLead()` capability to Flows and Agentforce — convert into new or existing Accounts, Contacts, and Opportunities, with inline renames, record types, Person Account awareness, and per-record success/error outputs that never fault your flow.

## Features

- **Bulk-safe** — one output per input, always in the same order, so record-triggered flows get the right results even when some conversions fail
- **Never faults your flow** — partial-success conversion (`allOrNone=false`); each output carries `isSuccess` and `errorMessage` so you can branch on failures
- **Auto-detects the converted status** — leave `Converted Status Name` blank and the action finds a converted status that works for the lead, even in orgs where record type business processes restrict which converted statuses are valid
- **Case-insensitive status matching** — "converted" and "Converted" both work; bad values return the list of valid ones in the error message
- **Convert into existing records** — optional Account, Contact, Opportunity, and Person Account targets
- **Full conversion options** — new owner, opportunity name, owner notification email, overwrite lead source
- **Blank-tolerant, type-checked inputs** — empty strings from Flow are treated as unset, and an Id of the wrong object is rejected by name ("Existing Contact Id must be a Contact Id, but an Account Id was supplied") instead of failing later with an opaque platform error
- **Bulk-chunked** — conversions are submitted in batches of 100, the documented maximum for `Database.convertLead`, so a record-triggered flow handing over 200 records is safe
- **Duplicate-rule parity** — alert-mode duplicate rules block `Database.convertLead()` in the API context even though the standard convert screen saves through them; this action restores that parity via `DuplicateRuleHeader.allowSave` (block-mode rules still block)
- **Inline renames** — optional Account Name, Contact First/Last Name, and Opportunity Name inputs rename the records right after conversion, like the standard convert screen's editable fields
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
| Enforce User Permissions | No | TRUE requires the running user to hold **Convert Leads** and applies their field-level security to post-conversion updates. Defaults to FALSE — see Security below |

## Outputs

| Output | Description |
|--------|-------------|
| Success | TRUE if the Lead converted |
| Error Message | Populated when Success is FALSE |
| Warning Message | Populated when the Lead converted but something after it needs attention — a rename that failed, a field blocked by field-level security, an ignored input, or a value another Lead in the same batch overrode |
| Account Id | Account the Lead was converted into |
| Contact Id | Contact the Lead was converted into |
| Opportunity Id | Opportunity created or converted into (null when skipped) |
| Person Account Id | Populated only when converting into an existing person account via the Person Account Id input |
| Is Person Account | TRUE when the converted Account is a Person Account. Always FALSE in orgs without Person Accounts |

## Person Accounts

In a Person Account org, a Lead with a **blank Company** converts into a Person Account — that part is platform behavior, and this action passes straight through to it. What the action adds on top:

- **Detects the result.** `Database.convertLead()` gives you no signal that it produced a Person Account (`getRelatedPersonAccountId()` stays null for newly created ones), so the action queries it back and returns **Is Person Account**.
- **Handles the person Contact for you.** The Apex Reference is explicit that converting into a Person Account must specify *only* the account — passing a Contact Id there is documented to error. Pass the Person Account Id as **Existing Account Id** and leave Existing Contact Id blank; if you supply one anyway it is ignored, with a warning explaining why.
- **Redirects the Account rename.** `Account.Name` is read-only on a Person Account (it is derived from the person's first/last name), so an **Account Name** input there returns a clear warning telling you to use **Contact First Name / Contact Last Name** instead — which do work, and update the account's name.
- **Validates record types.** A Person Account needs a person-type record type and a business account needs a business one; a mismatch is caught with an explanatory warning rather than a raw platform error.

### It does not require Person Accounts

Person Account fields (`IsPersonAccount`, `Account.FirstName`, `PersonContactId`, `RecordType.IsPersonType`) **do not exist** in orgs without Person Accounts — a static Apex or SOQL reference to any of them fails to compile there and would block the whole package from installing. Every such reference in this package is therefore dynamic (`sobject.get`/`put`, `Database.query`) behind a runtime existence check, and the Person Account logic simply never runs where the feature is off. The package is verified deploying and passing the full test suite in both a Person-Account org and a non-Person-Account org.

If you build your own screen for this, note that `Lead.Company` is nillable **only** in Person Account orgs — it is required otherwise — so "Company is blank" is a person-lead test that needs no Person Account field reference and therefore works in any org.

## Security

Like all Apex, this action runs in **system context**. Two consequences worth understanding before you expose it:

- `Database.convertLead()` succeeds even for a user who does **not** have the **Convert Leads** permission. Anyone who can run a Flow containing this action can convert leads. That is sometimes exactly what you want — removing the permission hides the standard Convert button and the Path's convert option, leaving your flow as the only route — but it is a privilege path either way.
- The post-conversion renames and record-type writes bypass field-level security, so a user without edit access to `Account.Name` can still rename through the action.

Set **Enforce User Permissions** to TRUE to opt out of both: the action then refuses to convert for a user lacking **Convert Leads**, and strips any field the running user cannot edit from the post-conversion updates, reporting what it dropped on `warningMessage`. It defaults to FALSE so existing behavior is unchanged.

Enforcement never throws. Field stripping deliberately runs without root-object CRUD enforcement, because that variant raises `NoAccessException` — which would fault the flow *after* the conversion had already committed, losing every result for work that actually happened. Object-level denials surface through the normal update-failure warning instead. Note also that Salesforce makes **Convert Leads** depend on Create/Edit/Read for Account, Contact, and Lead, so a user who can convert always has those; Opportunity access is *not* part of that dependency, which is why the Opportunity write path is the one that can be blocked.

## Why the status auto-detect matters

`Database.convertLead()` requires a converted Lead Status, but the valid value varies org to org — and it gets worse: if your Lead record types use business processes, an org-wide converted status can still be **invalid for a specific lead's record type**. This action handles both cases. Pass a status name if you want control; leave it blank and the action retries across every converted status in the org until one works for that lead.

Retries fire **only** when the platform rejects the status itself (`INVALID_STATUS`). A conversion that fails for any other reason — a validation rule, a bad Id, a duplicate block — is reported immediately, so you get the real cause rather than a status error from a later attempt, and a failing row costs one DML statement instead of one per candidate status.

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

The test class discovers a working converted status by trial conversion and derives its expectations from your org's own configuration, so it passes regardless of how your org renamed or restricted Lead Status values. Person Account assertions are skipped (not failed) in orgs without Person Accounts, and every Person Account reference in the tests is dynamic so they compile in both org shapes. Test data is inserted with duplicate rules bypassed (`DuplicateRuleHeader.allowSave`). Orgs with custom required fields or validation rules on Lead, Account, or Contact may still need those satisfied for tests to run.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `WSM_FlowLeadConverter` | Apex Class | **Convert Lead** invocable action |
| `WSM_FlowLeadConverterInputWrapper` | Apex Class | Convert Lead input variables |
| `WSM_FlowLeadConverterOutputWrapper` | Apex Class | Convert Lead output variables |
| `WSM_FlowLeadConverter_Test` | Apex Class | Convert Lead test coverage |

Apex only — no flows, layouts, or components are installed, so the action drops into whatever UI you already have.
