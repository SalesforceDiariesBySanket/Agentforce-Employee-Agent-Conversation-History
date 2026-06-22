# Agentforce Employee Agent Conversation History

A Salesforce Lightning Web Component that lets you browse, view, and continue **Agentforce Employee Agent** conversation sessions stored in **Salesforce Data Cloud**.

![Component Screenshot](https://raw.githubusercontent.com/SalesforceDiariesBySanket/Agentforce-Employee-Agent-Conversation-History/main/assets/preview.png)

> Built by [Sanket Kumar](https://salesforcediaries.com) — Salesforce Diaries

---

## What This Does

The `agentSessionViewer` LWC reads Agentforce conversation traces from three Data Cloud DMOs:

| DMO | Purpose |
|---|---|
| `ssot__AiAgentSession__dlm` | Session spine — one row per conversation |
| `ssot__AiAgentSessionParticipant__dlm` | User and Agent participants per session |
| `ssot__AiAgentInteractionMessage__dlm` | Individual messages (Input / Output) |

**Key features:**
- 📋 Left-pane session list filtered to **only the agents assigned to the running user** via Permission Sets
- 💬 Right-pane full conversation transcript with lazy "Load earlier" paging
- 🔄 **Continue in Agentforce** button — opens the live ACC panel and seeds the agent with the full prior context
- ⚡ Offset pagination for large session lists
- 🕐 Relative timestamps ("2h ago", "3d ago")

---

## Prerequisites

Before deploying, make sure the following are configured in your org.

### 1. Enable Salesforce Data Cloud

Data Cloud (formerly Customer Data Platform) must be provisioned in your org.

1. Go to **Setup → Data Cloud Setup**
2. Follow the provisioning wizard and accept the terms
3. Confirm that Data Cloud is **Active**

### 2. Enable Agentforce Session Tracing

The component reads conversation history from Data Cloud DMOs that are populated only when session tracing is active.

1. Go to **Setup → Agentforce Agents** (search "Agents" in Setup)
2. Open each Employee Agent you want to track
3. Under the agent's settings, enable **Session History** / **Conversation Tracing**
4. Alternatively, go to **Setup → Einstein → Einstein Setup** and ensure **Einstein AI Platform** is enabled
5. Confirm that `ssot__AiAgentSession__dlm` has rows in the **Data Cloud Data Explorer** after a test conversation

> **Note:** After enabling tracing, allow up to 15–30 minutes for the first sessions to appear in Data Cloud.

### 3. Required Permissions

Users who need to view conversation history must have:

| Permission | Where to Grant |
|---|---|
| **Data Cloud - Salesforce Connector User** or **Data Cloud Admin** | Profile or Permission Set |
| **View Setup and Configuration** | Profile or Permission Set |
| **Agent Access** (for each Employee Agent) | Permission Set → Agent Access |
| Access to the Lightning page where the component is placed | App / Tab visibility |

**Steps to assign Agent Access:**
1. Go to **Setup → Permission Sets**
2. Open (or create) the permission set for your users
3. Click **Agent Access** in the permission set
4. Add each Agentforce Employee Agent the user should see
5. Assign the permission set to the user

> The component automatically restricts the session list to **only the agents the running user is assigned to**. A user with no Agent Access assigned will see an empty list.

---

## Deployment

### Option A — Salesforce CLI (recommended)

```bash
# 1. Clone this repository
git clone https://github.com/SalesforceDiariesBySanket/Agentforce-Employee-Agent-Conversation-History.git
cd Agentforce-Employee-Agent-Conversation-History

# 2. Authenticate to your org
sf org login web --alias myOrg

# 3. Deploy
sf project deploy start --source-dir force-app --target-org myOrg
```

### Option B — Deploy with a scratch org

```bash
# Create scratch org (Einstein AI Platform feature is pre-configured)
sf org create scratch --definition-file config/project-scratch-def.json --alias agentScratch --duration-days 30

# Push source
sf project deploy start --source-dir force-app --target-org agentScratch

# Open the org
sf org open --target-org agentScratch
```

---

## Adding the Component to a Page

The component is available in the **Lightning App Builder** and can be placed on:

- ⚡ **Lightning App Page** (recommended — full-width layout)
- 🏠 **Home Page**
- 📄 **Record Page**

### Steps

1. Go to **Setup → Lightning App Builder** (or open any Lightning App and click ⚙️ → Edit Page)
2. In the component panel on the left, search for **"Agentforce Conversation Viewer"**
3. Drag it onto the page canvas (a **One Region** or **Two Column** layout works best)
4. Click **Save** → **Activate** → select the profiles/apps where it should appear
5. Click **Finish**

> For the best experience, place the component on a **full-width App Page** so both the session list pane and the conversation detail pane have enough room.

### Via URL (quick test)

After deploying, you can navigate directly to any Lightning App Page that hosts the component by opening your org and navigating to the page.

---

## Project Structure

```
force-app/
└── main/
    └── default/
        ├── classes/
        │   ├── AgentSessionController.cls          # @AuraEnabled controller (orchestration + paging)
        │   ├── AgentSessionGateway.cls             # Data-access interface (seam for testing)
        │   └── AgentSessionDlmGateway.cls          # Production Data Cloud queries
        └── lwc/
            └── agentSessionViewer/
                ├── agentSessionViewer.html         # Component template
                ├── agentSessionViewer.js           # Component logic
                ├── agentSessionViewer.css          # Styles
                └── agentSessionViewer.js-meta.xml  # Metadata (targets, properties)
```

---

## Architecture

```
LWC (agentSessionViewer)
    │
    │  @AuraEnabled (imperative)
    ▼
AgentSessionController.cls
    │
    │  Interface (injectable seam)
    ▼
AgentSessionGateway  ◄──── AgentSessionDlmGateway (production)
                             │
                             │  Dynamic SOQL on __dlm objects
                             ▼
                        Salesforce Data Cloud
                          ssot__AiAgentSession__dlm
                          ssot__AiAgentSessionParticipant__dlm
                          ssot__AiAgentInteractionMessage__dlm
```

---

## FAQ

**Q: I see an empty session list after deploying.**  
A: Check that (1) the user has Agent Access via a Permission Set, (2) Data Cloud session tracing is enabled on the agent, and (3) at least one conversation has been completed with the agent.

**Q: The "Continue in Agentforce" button is greyed out.**  
A: The button requires the `BotDefinition.Id` to be resolved. Make sure the agent's `DeveloperName` in the org matches the `ssot__AiAgentApiName__c` stored in Data Cloud.

**Q: Sessions appear but show no messages.**  
A: The session and message DMOs in Data Cloud ingest on independent schedules. Wait a few minutes and refresh.

**Q: Can I filter by date or search by keyword?**  
A: The current version filters only by agent. Date filtering and keyword search can be added as future enhancements.

---

## Resources

- [Salesforce Data Cloud Docs](https://help.salesforce.com/s/articleView?id=sf.c360_a_data_cloud.htm)
- [Agentforce Documentation](https://developer.salesforce.com/docs/einstein/genai/guide/agentforce.html)
- [Lightning App Builder](https://help.salesforce.com/s/articleView?id=sf.lightning_app_builder_overview.htm)
- [Blog: Salesforce Diaries by Sanket](https://salesforcediaries.com)

---

## License

MIT — free to use, modify, and distribute.

> The content in this repository reflects personal views and does not represent any employer or affiliated organization.
