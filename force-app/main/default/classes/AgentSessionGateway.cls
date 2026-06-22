/**
 * Data-access seam for AgentSessionController.
 *
 * Every Data Cloud (__dlm) query and every setup/permission query lives behind this interface so the
 * controller holds only orchestration (filter resolution, sorting, paging, UUID joins). __dlm objects
 * are backed by external Data Cloud callouts, so the real queries can only run outside Apex test context.
 *
 * Filter model: the session object (__dlm) carries no agent type or agent name and cannot be joined, so
 * the set of matching session UUIDs is resolved from the participant object first, then the session rows
 * (with timestamps, for date filtering + sorting) are fetched for that set. DLM cannot ORDER BY COUNT and
 * its LIKE is case-sensitive, so message-count sorting and case-insensitive search are done in Apex.
 *
 * "My agents" is real, queryable assignment: PermissionSetAssignment -> SetupEntityAccess
 * (SetupEntityType = 'BotDefinition') -> BotDefinition.DeveloperName (== ssot__AiAgentApiName__c).
 */
public interface AgentSessionGateway {
    /** DeveloperNames of employee agents assigned to the running user via permission set (Agent Access). */
    Set<String> myAgentApiNames();

    /**
     * Distinct session UUIDs of the given agent type whose agent api name is in `agentNames`. When
     * `agentNames` is null/empty the name constraint is dropped (all sessions of that type). Capped at max.
     */
    Set<String> sessionIdsForAgentNames(Set<String> agentNames, String agentType, Integer max);

    /**
     * Session rows for the given UUIDs, capped at max.
     * Returns ssot__Id__c, ssot__AiAgentChannelType__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c.
     * Unordered - the controller sorts in Apex.
     */
    List<SObject> sessionsByIds(Set<String> sessionIds, Integer max);

    /** Participant rows for a set of session UUIDs (list enrichment). */
    List<SObject> participantsForSessions(Set<String> sessionIds);

    /** Map of session UUID -> message count, for the given sessions. */
    Map<String, Integer> messageCountBySession(Set<String> sessionIds);

    /**
     * Map of session UUID -> latest message send time, for the given sessions. Used to order and
     * timestamp sessions whose session-spine row has not yet ingested in Data Cloud (so they still
     * appear newest-first instead of being dropped). Sessions with no timestamped message are absent.
     */
    Map<String, Datetime> latestMessageTimeBySession(Set<String> sessionIds);

    /** Participant rows for a single session UUID (detail view identity map). */
    List<SObject> participantsForSession(String sessionId);

    /** Messages for a single session UUID, ordered by send time asc, capped at maxRows. */
    List<SObject> messagesForSession(String sessionId, Integer maxRows);

    /** Total message count for a single session UUID. */
    Integer messageCountForSession(String sessionId);

    /**
     * One window of a session's messages ordered NEWEST-first (send time desc, id desc as tiebreak),
     * `pageSize` rows starting at `offset` from the newest end. Used for lazy "load earlier" paging.
     */
    List<SObject> messagesPageDesc(String sessionId, Integer offset, Integer pageSize);

    /** BotDefinition.Id for an agent DeveloperName, or null. */
    String botIdFor(String agentApiName);

    /** Map of User Id -> Name for the given ids, for showing a friendly participant name instead of an id. */
    Map<Id, String> userNamesByIds(Set<Id> userIds);
}