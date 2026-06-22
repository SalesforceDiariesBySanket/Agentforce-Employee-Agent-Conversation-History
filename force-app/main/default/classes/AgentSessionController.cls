/**
 * Read-only controller for the `agentSessionViewer` LWC.
 *
 * Surfaces Agentforce conversation traces stored in Data Cloud as Data Model Objects (DMOs / __dlm):
 *   ssot__AiAgentSession__dlm             - one row per conversation session (the spine)
 *   ssot__AiAgentInteractionMessage__dlm  - one row per Input/Output message
 *   ssot__AiAgentSessionParticipant__dlm  - the USER (005...) and AGENT participants on a session
 *
 * The list is always restricted to Agentforce EMPLOYEE-agent sessions (service-agent sessions excluded)
 * and to the agents assigned to the running user. There is a single filter: an optional agent api name -
 * blank/null means "all of my assigned agents", a value narrows to that one agent.
 *
 * The filter is passed as a primitive String (not a wrapper object): a complex Apex parameter was arriving
 * with all fields null over the Aura wire (verified in the org debug logs), which silently dropped the
 * agent restriction. A primitive arg removes that (de)serialization seam entirely.
 *
 * Data-model constraints that shape this code (all verified against the org):
 *   - __dlm has no relationship traversal, so message<->identity and session<->agent joins are done in
 *     Apex on the session UUID.
 *   - The session object carries no agent type/name, so the matching session-id set is resolved from the
 *     participant object first, then session rows are fetched for that set.
 *   - "My agents" is real assignment: PermissionSetAssignment -> SetupEntityAccess(BotDefinition) ->
 *     BotDefinition.DeveloperName (which equals ssot__AiAgentApiName__c in the traces).
 *
 * All data access goes through the injectable `gateway` seam so the orchestration is isolated.
 */
public with sharing class AgentSessionController {
    private static final Integer DEFAULT_PAGE_SIZE = 20;
    // Transcript is lazy-loaded newest-first: the initial open fetches only the latest page, and the LWC
    // pulls older windows on demand. Keeps getConversation cheap for long sessions.
    private static final Integer DEFAULT_MESSAGE_PAGE_SIZE = 10;
    // Caps on distinct sessions / rows; must exceed the org's real counts so nothing is silently truncated.
    private static final Integer MAX_SESSIONS = 50000;
    private static final Integer MAX_MESSAGES = 500;

    private static final String ROLE_USER = 'USER';
    private static final String ROLE_AGENT = 'AGENT';
    private static final String NOT_SET = 'NOT_SET';
    private static final String AGENT_TYPE_EMPLOYEE = 'AgentforceEmployeeAgent';

    /** Data-access seam. Production default; tests overwrite with a stub. */
    @TestVisible
    private static AgentSessionGateway gateway = new AgentSessionDlmGateway();

    // ---- Wire result shapes -------------------------------------------------

    public class AgentOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public AgentOption(String v) {
            this.value = v;
            this.label = v;
        }
    }

    public class FilterOptions {
        @AuraEnabled public List<AgentOption> myAgents = new List<AgentOption>();
        @AuraEnabled public Boolean hasAssignedAgents = false;
    }

    public class SessionSummary {
        @AuraEnabled public String sessionId;
        @AuraEnabled public String channelType;
        @AuraEnabled public Datetime startTime;
        @AuraEnabled public Datetime endTime;
        @AuraEnabled public String agentApiName;
        @AuraEnabled public String userParticipantId;
        @AuraEnabled public String userName; // resolved User.Name; falls back to the id when unresolvable
        @AuraEnabled public Integer messageCount;
    }

    public class SessionPage {
        @AuraEnabled public List<SessionSummary> sessions = new List<SessionSummary>();
        @AuraEnabled public Integer nextOffset;
        @AuraEnabled public Boolean hasMore = false;
        @AuraEnabled public Integer totalSessions = 0;
    }

    public class ConversationMessage {
        @AuraEnabled public String id;
        @AuraEnabled public String messageType;
        @AuraEnabled public String text;
        @AuraEnabled public Datetime sentTime;
        @AuraEnabled public String participantId;
        @AuraEnabled public String participantObject;
        @AuraEnabled public String role;
        @AuraEnabled public Boolean fromUser;
    }

    public class ConversationDetail {
        @AuraEnabled public String sessionId;
        @AuraEnabled public String agentApiName;
        @AuraEnabled public String botId;
        @AuraEnabled public String userParticipantId;
        @AuraEnabled public String userName; // resolved User.Name; falls back to the id when unresolvable
        // `messages` holds only the latest window (ascending). totalMessages/loadedCount/hasEarlier let the
        // LWC show "load earlier" and know when the whole transcript is in hand.
        @AuraEnabled public Integer totalMessages = 0;
        @AuraEnabled public Integer loadedCount = 0;
        @AuraEnabled public Boolean hasEarlier = false;
        @AuraEnabled public List<ConversationMessage> messages = new List<ConversationMessage>();
    }

    /** One older window of a transcript, returned ascending, plus whether still-older messages remain. */
    public class MessagePage {
        @AuraEnabled public List<ConversationMessage> messages = new List<ConversationMessage>();
        @AuraEnabled public Boolean hasEarlier = false;
    }

    // ---- Public API ---------------------------------------------------------

    /** Dropdown options: the employee agents assigned to the running user (via permission set). */
    @AuraEnabled
    public static FilterOptions getFilterOptions() {
        FilterOptions opt = new FilterOptions();
        List<String> mine = new List<String>(gateway.myAgentApiNames());
        mine.sort();
        for (String n : mine) {
            opt.myAgents.add(new AgentOption(n));
        }
        opt.hasAssignedAgents = !opt.myAgents.isEmpty();
        return opt;
    }

    /**
     * One page of employee-agent sessions, newest-first, offset-paginated.
     *
     * The only filter is `agentApiName`, a primitive String passed straight from the LWC: blank/null means
     * "all of the running user's assigned agents"; a value narrows to that single agent. `offset` is the
     * 0-based paging offset.
     *
     * NOT cacheable: invoked imperatively with a changing agent selection; a storable (cacheable) action
     * would replay the first page for every later selection, making the filter look like a no-op.
     */
    @AuraEnabled
    public static SessionPage getSessionPage(String agentApiName, Integer offset) {
        Integer off = (offset == null || offset < 0) ? 0 : offset;
        SessionPage page = new SessionPage();

        // 1) Resolve the agent-name restriction. Blank = all of the running user's assigned agents.
        Set<String> nameRestriction;
        if (String.isNotBlank(agentApiName)) {
            nameRestriction = new Set<String>{ agentApiName.trim() };
        } else {
            nameRestriction = gateway.myAgentApiNames();
            if (nameRestriction.isEmpty()) {
                return page; // user has no assigned agents -> nothing to show
            }
        }

        // 2) Resolve the candidate session-id set from participants (employee type enforced). This is the
        //    master set: a session is "in the list" if it has any employee-agent conversation trace.
        Set<String> ids = gateway.sessionIdsForAgentNames(nameRestriction, AGENT_TYPE_EMPLOYEE, MAX_SESSIONS);
        if (ids.isEmpty()) {
            return page;
        }

        // 3) LEFT-join the session-spine rows. In Data Cloud the Session, Participant and Message DMOs
        //    ingest on independent schedules, so a brand-new conversation can have participants + messages
        //    before its session-spine row lands. We key the spine rows by id and treat the rest as
        //    "spine-less" (still shown) rather than dropping them.
        Map<String, SObject> spineById = new Map<String, SObject>();
        for (SObject s : gateway.sessionsByIds(ids, MAX_SESSIONS)) {
            spineById.put((String) s.get('ssot__Id__c'), s);
        }

        // 3b) For spine-less ids, derive recency from the latest message time so they still sort by
        //     newest. Queried only for that subset to keep the extra aggregate small.
        Set<String> spineless = new Set<String>(ids);
        spineless.removeAll(spineById.keySet());
        Map<String, Datetime> latestMsgTime = spineless.isEmpty()
            ? new Map<String, Datetime>()
            : gateway.latestMessageTimeBySession(spineless);

        // 4) Sort the FULL id set newest-first in Apex (the joined set is assembled here, not orderable in
        //    DLM). Spine rows sort by end (else start) timestamp; spine-less rows by latest message time.
        List<SortableSession> sortable = new List<SortableSession>();
        for (String sid : ids) {
            SObject spine = spineById.get(sid);
            Datetime sortTime;
            if (spine != null) {
                Datetime endT = (Datetime) spine.get('ssot__EndTimestamp__c');
                sortTime = (endT != null) ? endT : (Datetime) spine.get('ssot__StartTimestamp__c');
            } else {
                sortTime = latestMsgTime.get(sid);
            }
            sortable.add(new SortableSession(sid, spine, sortTime));
        }
        sortable.sort();
        page.totalSessions = sortable.size();

        // 5) Slice the requested page by offset.
        if (off >= sortable.size()) {
            return page; // past the end
        }
        Integer endIdx = Math.min(off + DEFAULT_PAGE_SIZE, sortable.size());
        List<SortableSession> pageSlice = new List<SortableSession>();
        for (Integer i = off; i < endIdx; i++) {
            pageSlice.add(sortable[i]);
        }
        page.hasMore = endIdx < sortable.size();
        page.nextOffset = page.hasMore ? endIdx : null;

        // 6) Enrich only the page slice (participants + message counts). Both work for spine-less sessions
        //    because their participant and message rows are present even when the session row isn't.
        Set<String> pageIds = new Set<String>();
        for (SortableSession ss : pageSlice) {
            pageIds.add(ss.sessionId);
        }
        Map<String, ParticipantInfo> partBySession = participantInfoBySession(pageIds);
        Map<String, Integer> countBySession = gateway.messageCountBySession(pageIds);

        for (SortableSession ss : pageSlice) {
            String sid = ss.sessionId;
            SessionSummary sum = new SessionSummary();
            sum.sessionId = sid;
            if (ss.spine != null) {
                sum.channelType = (String) ss.spine.get('ssot__AiAgentChannelType__c');
                sum.startTime = (Datetime) ss.spine.get('ssot__StartTimestamp__c');
                sum.endTime = (Datetime) ss.spine.get('ssot__EndTimestamp__c');
            } else {
                // Session-spine row not ingested yet: no channel/start/end. Surface the message-derived
                // time as startTime so the row still shows a (relative) timestamp in the list.
                sum.startTime = ss.sortTime;
            }
            ParticipantInfo pi = partBySession.get(sid);
            if (pi != null) {
                sum.agentApiName = pi.agentApiName;
                sum.userParticipantId = pi.userParticipantId;
            }
            sum.messageCount = countBySession.containsKey(sid) ? countBySession.get(sid) : 0;
            page.sessions.add(sum);
        }

        // Resolve user ids -> names for the whole page in one query; fall back to the raw id.
        Set<String> userIds = new Set<String>();
        for (SessionSummary sum : page.sessions) {
            if (String.isNotBlank(sum.userParticipantId)) {
                userIds.add(sum.userParticipantId);
            }
        }
        Map<String, String> namesById = resolveUserNames(userIds);
        for (SessionSummary sum : page.sessions) {
            String resolvedName = namesById.get(sum.userParticipantId);
            sum.userName = String.isNotBlank(resolvedName) ? resolvedName : sum.userParticipantId;
        }
        return page;
    }

    /**
     * Opening view of one session UUID: resolved identities, BotDefinition.Id, and ONLY the latest window
     * of messages (newest end, returned ascending). Older windows are pulled lazily via getEarlierMessages;
     * the full transcript (e.g. to seed "Continue") via getAllMessages.
     */
    @AuraEnabled
    public static ConversationDetail getConversation(String sessionId) {
        ConversationDetail detail = new ConversationDetail();
        if (String.isBlank(sessionId)) {
            return detail;
        }
        detail.sessionId = sessionId;

        Map<String, ParticipantRow> byUuid = new Map<String, ParticipantRow>();
        ParticipantInfo info = loadParticipants(sessionId, byUuid);
        detail.agentApiName = info.agentApiName;
        detail.userParticipantId = info.userParticipantId;
        if (String.isNotBlank(info.userParticipantId)) {
            String resolvedName = resolveUserNames(new Set<String>{ info.userParticipantId })
                .get(info.userParticipantId);
            detail.userName = String.isNotBlank(resolvedName) ? resolvedName : info.userParticipantId;
        }
        detail.botId = gateway.botIdFor(info.agentApiName);

        Integer total = gateway.messageCountForSession(sessionId);
        detail.totalMessages = total;

        // Latest window comes back newest-first from the gateway; reverse to ascending for the chat view.
        List<ConversationMessage> latest = toMessagesAscending(
            gateway.messagesPageDesc(sessionId, 0, DEFAULT_MESSAGE_PAGE_SIZE),
            byUuid
        );
        detail.messages = latest;
        detail.loadedCount = latest.size();
        detail.hasEarlier = total > detail.loadedCount;
        return detail;
    }

    /**
     * An older window of a transcript. `loadedCount` is how many messages the client already holds from the
     * newest end; this returns the next `pageSize` older messages (ascending), and whether still-older remain.
     */
    @AuraEnabled
    public static MessagePage getEarlierMessages(String sessionId, Integer loadedCount, Integer pageSize) {
        MessagePage page = new MessagePage();
        if (String.isBlank(sessionId)) {
            return page;
        }
        Integer offset = (loadedCount == null || loadedCount < 0) ? 0 : loadedCount;
        Integer size = (pageSize == null || pageSize <= 0)
            ? DEFAULT_MESSAGE_PAGE_SIZE
            : Math.min(pageSize, MAX_MESSAGES);

        Map<String, ParticipantRow> byUuid = new Map<String, ParticipantRow>();
        loadParticipants(sessionId, byUuid);

        page.messages = toMessagesAscending(gateway.messagesPageDesc(sessionId, offset, size), byUuid);
        Integer total = gateway.messageCountForSession(sessionId);
        page.hasEarlier = total > (offset + page.messages.size());
        return page;
    }

    /**
     * Full transcript (ascending), used to seed "Continue in Agentforce" with complete context regardless
     * of how much of the conversation the user has lazily loaded on screen.
     */
    @AuraEnabled
    public static List<ConversationMessage> getAllMessages(String sessionId) {
        List<ConversationMessage> out = new List<ConversationMessage>();
        if (String.isBlank(sessionId)) {
            return out;
        }
        Map<String, ParticipantRow> byUuid = new Map<String, ParticipantRow>();
        loadParticipants(sessionId, byUuid);
        for (SObject m : gateway.messagesForSession(sessionId, MAX_MESSAGES)) {
            out.add(toMessage(m, byUuid));
        }
        return out;
    }

    // ---- Sorting ------------------------------------------------------------

    private class SortableSession implements Comparable {
        public String sessionId;
        public SObject spine;
        public Datetime sortTime;

        public SortableSession(String sessionId, SObject spine, Datetime sortTime) {
            this.sessionId = sessionId;
            this.spine = spine;
            this.sortTime = sortTime;
        }

        /** Newest-first by sortTime (nulls last), then session id descending as a stable tiebreak. */
        public Integer compareTo(Object o) {
            SortableSession other = (SortableSession) o;
            if (this.sortTime != other.sortTime) {
                if (this.sortTime == null) {
                    return 1; // nulls last
                }
                if (other.sortTime == null) {
                    return -1;
                }
                return other.sortTime > this.sortTime ? 1 : -1; // desc
            }
            if (this.sessionId == other.sessionId) {
                return 0;
            }
            return (this.sessionId > other.sessionId) ? -1 : 1;
        }
    }

    // ---- Helpers ------------------------------------------------------------

    private class ParticipantRow {
        String participantId;
        String participantObject;
        String role;
    }

    private static ParticipantInfo loadParticipants(String sessionId, Map<String, ParticipantRow> byUuid) {
        ParticipantInfo info = new ParticipantInfo();
        for (SObject p : gateway.participantsForSession(sessionId)) {
            ParticipantRow r = new ParticipantRow();
            r.participantId = (String) p.get('ssot__ParticipantId__c');
            r.participantObject = (String) p.get('ssot__ParticipantObject__c');
            r.role = (String) p.get('ssot__AiAgentSessionParticipantRole__c');
            byUuid.put((String) p.get('ssot__Id__c'), r);
            accumulate(info, r.role, r.participantId, (String) p.get('ssot__AiAgentApiName__c'));
        }
        return info;
    }

    private static ConversationMessage toMessage(SObject m, Map<String, ParticipantRow> byUuid) {
        ConversationMessage cm = new ConversationMessage();
        cm.id = (String) m.get('ssot__Id__c');
        cm.messageType = (String) m.get('ssot__AiAgentInteractionMessageType__c');
        cm.text = (String) m.get('ssot__ContentText__c');
        cm.sentTime = (Datetime) m.get('ssot__MessageSentTimestamp__c');
        ParticipantRow r = byUuid.get((String) m.get('ssot__AiAgentSessionParticipantId__c'));
        if (r != null) {
            cm.participantId = r.participantId;
            cm.participantObject = r.participantObject;
            cm.role = r.role;
        }
        cm.fromUser = (cm.role == ROLE_USER);
        return cm;
    }

    private static List<ConversationMessage> toMessagesAscending(
        List<SObject> descRows,
        Map<String, ParticipantRow> byUuid
    ) {
        List<ConversationMessage> out = new List<ConversationMessage>();
        for (Integer i = descRows.size() - 1; i >= 0; i--) {
            out.add(toMessage(descRows[i], byUuid));
        }
        return out;
    }

    private class ParticipantInfo {
        String agentApiName;
        String userParticipantId;
    }

    private static void accumulate(ParticipantInfo info, String role, String pid, String agentApiName) {
        if (String.isNotBlank(agentApiName) && agentApiName != NOT_SET && (info.agentApiName == null || role == ROLE_AGENT)) {
            info.agentApiName = agentApiName;
        }
        if (info.userParticipantId == null && role == ROLE_USER && String.isNotBlank(pid) && pid != NOT_SET) {
            info.userParticipantId = pid;
        }
    }

    private static Map<String, ParticipantInfo> participantInfoBySession(Set<String> sessionIds) {
        Map<String, ParticipantInfo> out = new Map<String, ParticipantInfo>();
        for (SObject p : gateway.participantsForSessions(sessionIds)) {
            String sid = (String) p.get('ssot__AiAgentSessionId__c');
            ParticipantInfo info = out.get(sid);
            if (info == null) {
                info = new ParticipantInfo();
                out.put(sid, info);
            }
            accumulate(
                info,
                (String) p.get('ssot__AiAgentSessionParticipantRole__c'),
                (String) p.get('ssot__ParticipantId__c'),
                (String) p.get('ssot__AiAgentApiName__c')
            );
        }
        return out;
    }

    private static Map<String, String> resolveUserNames(Set<String> participantIds) {
        Map<String, String> namesByRawId = new Map<String, String>();
        Set<Id> userIds = new Set<Id>();
        for (String raw : participantIds) {
            if (String.isBlank(raw) || raw == NOT_SET) {
                continue;
            }
            try {
                Id uid = (Id) raw;
                if (String.valueOf(uid).startsWith('005')) {
                    userIds.add(uid);
                }
            } catch (Exception ignored) {
                // Not an Id (free-form participant) - leave it for the raw-id fallback.
            }
        }
        Map<Id, String> resolved = gateway.userNamesByIds(userIds);
        for (Id uid : resolved.keySet()) {
            namesByRawId.put((String) uid, resolved.get(uid));
        }
        return namesByRawId;
    }
}