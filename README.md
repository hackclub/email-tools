# Sync your Airtable bases to Loops!

- Automatically create and sync fields from Airtable to contact properties in Loops
- Automatically add people from Airtable to lists on Loops without re-subscribing them if they've already unsubscribed

## Tutorial

Supported fields: 

- Fields (your table in Airtable must have a field called "Email" with the person's email):
  - `Loops - highwaySignedUpAt` will upsert the Airtable value for the row into Loops (if the Airtable field is null, it will not overwrite the Loops value)
  - `Loops - Override - highwaySignedUpAt` will copy the Airtable value for the row into Loops, overwriting any existing value in Loops
  - `Loops - Special - setFullName` - Uses AI to break a full name (including preferred name) into parts for Loops. This is a good way to get high quality names in Loops.
  - `Loops - Special - setFullAddress` - Uses AI to break a given full address into individual parts. This does not geocode. It just breaks into parts.
  - `Loops List - {Note}` - Set value to a comma separated list of mailing list IDs to add the email to. This will not re-subscribe users who have previously unsubscribed from a list.
    - Ex. Field name: `Loops List - 3 Cool Things`. Value: `cm96o4ubl02b30i1n6l1jctbb`
   
# How to add properties to Loops contacts

First, identify which properties you want to set in Loops. You should always do `programSignUpAt` at a minimum.

It is better to create timestamped properties than boolean properties.

- Create `highwaySignUpAt -> timestamp` instead of `highwaySignUp -> true/false`
- Create `hackatimeFirstHeartbeatReceivedAt -> timestamp` instead of `hackatimeReceivedHeartbeat -> true/false`.

1. Create a field in your Airtable called `Loops - {eventName}` (must be lowerCamelCase, ex. `Loops - highwaySignedUpAt`). If you are running a YSWS, the event **MUST** be prefixed with your YSWS's name (the lowerCamelCase name of your program in the "YSWS Programs" table of the Unified YSWS Projects DB). Examples: `Athena Award -> athenaAward`, `Hackcraft Mod Edition -> hackcraftModEdition`, `Milkyway -> milkyway`.

<img width="598" height="60" alt="Screenshot 2025-11-05 at 8 15 00 PM" src="https://github.com/user-attachments/assets/263d0994-a573-4916-9243-a7dd187c1b3f" />

2. Verify that you table has a column called "Email" (case insenstiive)

3. When you set a value to `Loops - toyboxSignUpAt`, it will automatically be picked up and synced to Loops. In most cases, it should happen in under 5 minutes.

4. Recommendation: I recommend using `Created time` field types for fields like `Loops - toyboxSignUpAt`. If you have a field like `Project Name`, I recommend using Formula fields to sync that value to a field called `Loops - toyboxProjectName` (instead of writing directly into the field).

![toyboxsubmittedat](https://github.com/user-attachments/assets/7179fe59-7208-469a-8843-20838af491f7)

![formulaexample](https://github.com/user-attachments/assets/963d5f2a-6505-4a0a-8eb7-b3f06f207fb3)

Currently supported:

- Select specific Airtable bases to sync

## Config

```
# required - airtable token with access to whatever bases you want it to poll
AIRTABLE_PERSONAL_ACCESS_TOKEN=
# required - for updating loops contacts
LOOPS_API_KEY=
# required - for splitting addresses and full names into individual parts, and for alt unsubscribe contact merging
OPENAI_API_KEY=
# optional - OpenAI model / reasoning effort for name+address splitting (default: gpt-5.6-luna / low)
LLM_MODEL=
LLM_REASONING_EFFORT=
# optional - OpenAI model / reasoning effort for alt unsubscribe contact merging (default: gpt-5.6-terra / high)
LLM_MERGE_MODEL=
LLM_MERGE_REASONING_EFFORT=
# optional - ID of the mailing list to automatically add all new contacts to, ex. "Announcements"
DEFAULT_LOOPS_LIST_ID=
# optional - URL of a readonly user to the prod database for easier debugging
PROD_READONLY_DATABASE_URL=
# URL for the read-only warehouse database containing the loops.audience table
WAREHOUSE_LOOPS_AUDIENCE_READONLY_URL=
# required - Transactional email ID for sending alt unsubscribe results
LOOPS_ALT_UNSUBSCRIBE_RESULTS_TRANSACTIONAL_ID=
# required - Transactional email ID for sending OTP codes
LOOPS_OTP_TRANSACTIONAL_ID=

# must be set on 1 of the sidekiq workers. this will cause that worker to queue cron jobs
SIDEKIQ_SCHEDULER=1
```

## To-Do

- Re-subscribe support (dangerous, needs to be implemented carefully)
- Write-back to SyncSource with status so users can see success / error
  - Maybe pull from envelopes? Show detailed errors
- For `LlmCache`, we probably don't need to store the full request. Hash is probably enough.