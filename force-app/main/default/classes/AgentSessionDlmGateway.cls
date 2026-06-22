/**
 * Production AgentSessionGateway: the real Data Cloud (__dlm) and setup/permission queries.
 *
 * All dynamic SOQL uses bind variables (never string concatenation of user input), so it is injection-safe.
 * The __dlm queries run as live Data Cloud callouts and therefore only execute outside Apex test context.
 */
public with sharing class AgentSessionDlmGateway implements AgentSessionGateway {
    /**
     * Which agents the running user is allowed to see, by DeveloperName.
     *
     * Walks the real assignment chain in three setup queries: the user's PermissionSetAssignments ->
     * their SetupEntityAccess rows of type 'BotDefinition' (this is how "Agent Access" is stored) ->
     * the matching BotDefinition.DeveloperName. That DeveloperName equals ssot__AiAgentApiName__c in the
     * Data Cloud traces, so it is the key used to filter sessions. Returns empty at any broken link
     * (no perm sets, no agent access) - i.e. the user sees nothing.
     */
    public Set<String> myAgentApiNames() {
        Id me = UserInfo.getUserId();
        Set<Id> permSetIds = new Set<Id>();
        for (PermissionSetAssignment psa : [SELECT PermissionSetId FROM PermissionSetAssignment WHERE AssigneeId = :me]) {
            permSetIds.add(psa.PermissionSetId);
        }
        if (permSetIds.isEmpty()) {
            return new Set<String>();
        }
        Set<Id> botIds = new Set<Id>();
        for (SetupEntityAccess sea : [
            SELECT SetupEntityId FROM SetupEntityAccess
            WHERE ParentId IN :permSetIds AND SetupEntityType = 'BotDefinition'
        ]) {
            botIds.add(sea.SetupEntityId);
        }
        if (botIds.isEmpty()) {
            return new Set<String>();
        }
        Set<String> names = new Set<String>();
        for (BotDefinition b : [SELECT DeveloperName FROM BotDefinition WHERE Id IN :botIds]) {
            names.add(b.DeveloperName);
        }
        return names;
    }

    public Set<String> sessionIdsForAgentNames(Set<String> agentNames, String agentType, Integer max) {
        String aType = agentType;
        Set<String> names = agentNames;
        Boolean hasNames = agentNames != null && !agentNames.isEmpty();
        String q =
            'SELECT ssot__AiAgentSessionId__c FROM ssot__AiAgentSessionParticipant__dlm ' +
            'WHERE ssot__AiAgentType__c = :aType ' +
            (hasNames ? 'AND ssot__AiAgentApiName__c IN :names ' : '') +
            'GROUP BY ssot__AiAgentSessionId__c LIMIT ' + safeLimit(max);
        Set<String> ids = new Set<String>();
        for (SObject p : Database.query(q)) {
            String sid = (String) p.get('ssot__AiAgentSessionId__c');
            if (String.isNotBlank(sid)) {
                ids.add(sid);
            }
        }
        return ids;
    }

    public List<SObject> sessionsByIds(Set<String> sessionIds, Integer max) {
        Set<String> ids = sessionIds;
        String q =
            'SELECT ssot__Id__c, ssot__AiAgentChannelType__c, ssot__StartTimestamp__c, ssot__EndTimestamp__c ' +
            'FROM ssot__AiAgentSession__dlm WHERE ssot__Id__c IN :ids ' +
            'LIMIT ' + safeLimit(max);
        List<SObject> out = new List<SObject>();
        for (SObject s : Database.query(q)) {
            out.add(s);
        }
        return out;
    }

    public List<SObject> participantsForSessions(Set<String> sessionIds) {
        return Database.query(
            'SELECT ssot__AiAgentSessionId__c, ssot__ParticipantId__c, ssot__ParticipantObject__c, ' +
            'ssot__AiAgentSessionParticipantRole__c, ssot__AiAgentApiName__c ' +
            'FROM ssot__AiAgentSessionParticipant__dlm WHERE ssot__AiAgentSessionId__c IN :sessionIds'
        );
    }

    public Map<String, Integer> messageCountBySession(Set<String> sessionIds) {
        Map<String, Integer> out = new Map<String, Integer>();
        for (SObject ar : Database.query(
            'SELECT ssot__AiAgentSessionId__c sid, COUNT(Id) c FROM ssot__AiAgentInteractionMessage__dlm ' +
            'WHERE ssot__AiAgentSessionId__c IN :sessionIds GROUP BY ssot__AiAgentSessionId__c'
        )) {
            out.put((String) ar.get('sid'), (Integer) ar.get('c'));
        }
        return out;
    }

    public Map<String, Datetime> latestMessageTimeBySession(Set<String> sessionIds) {
        Map<String, Datetime> out = new Map<String, Datetime>();
        for (SObject ar : Database.query(
            'SELECT ssot__AiAgentSessionId__c sid, MAX(ssot__MessageSentTimestamp__c) mx ' +
            'FROM ssot__AiAgentInteractionMessage__dlm ' +
            'WHERE ssot__AiAgentSessionId__c IN :sessionIds GROUP BY ssot__AiAgentSessionId__c'
        )) {
            out.put((String) ar.get('sid'), (Datetime) ar.get('mx'));
        }
        return out;
    }

    public List<SObject> participantsForSession(String sessionId) {
        return Database.query(
            'SELECT ssot__Id__c, ssot__ParticipantId__c, ssot__ParticipantObject__c, ' +
            'ssot__AiAgentSessionParticipantRole__c, ssot__AiAgentApiName__c ' +
            'FROM ssot__AiAgentSessionParticipant__dlm WHERE ssot__AiAgentSessionId__c = :sessionId'
        );
    }

    public List<SObject> messagesForSession(String sessionId, Integer maxRows) {
        Integer lim = maxRows;
        return Database.query(
            'SELECT ssot__Id__c, ssot__AiAgentInteractionMessageType__c, ssot__AiAgentSessionParticipantId__c, ' +
            'ssot__ContentText__c, ssot__MessageSentTimestamp__c ' +
            'FROM ssot__AiAgentInteractionMessage__dlm WHERE ssot__AiAgentSessionId__c = :sessionId ' +
            'ORDER BY ssot__MessageSentTimestamp__c ASC LIMIT :lim'
        );
    }

    public Integer messageCountForSession(String sessionId) {
        String sid = sessionId;
        for (SObject ar : Database.query(
            'SELECT COUNT(ssot__Id__c) c FROM ssot__AiAgentInteractionMessage__dlm ' +
            'WHERE ssot__AiAgentSessionId__c = :sid'
        )) {
            Integer c = (Integer) ar.get('c');
            return (c == null) ? 0 : c;
        }
        return 0;
    }

    public List<SObject> messagesPageDesc(String sessionId, Integer offset, Integer pageSize) {
        Integer off = (offset == null || offset < 0) ? 0 : offset;
        Integer lim = (pageSize == null || pageSize <= 0) ? 10 : pageSize;
        return Database.query(
            'SELECT ssot__Id__c, ssot__AiAgentInteractionMessageType__c, ssot__AiAgentSessionParticipantId__c, ' +
            'ssot__ContentText__c, ssot__MessageSentTimestamp__c ' +
            'FROM ssot__AiAgentInteractionMessage__dlm WHERE ssot__AiAgentSessionId__c = :sessionId ' +
            'ORDER BY ssot__MessageSentTimestamp__c DESC, ssot__Id__c DESC LIMIT :lim OFFSET :off'
        );
    }

    public String botIdFor(String agentApiName) {
        if (String.isBlank(agentApiName)) {
            return null;
        }
        List<BotDefinition> bots = [SELECT Id FROM BotDefinition WHERE DeveloperName = :agentApiName LIMIT 1];
        return bots.isEmpty() ? null : String.valueOf(bots[0].Id);
    }

    public Map<Id, String> userNamesByIds(Set<Id> userIds) {
        Map<Id, String> out = new Map<Id, String>();
        if (userIds == null || userIds.isEmpty()) {
            return out;
        }
        for (User u : [SELECT Id, Name FROM User WHERE Id IN :userIds]) {
            out.put(u.Id, u.Name);
        }
        return out;
    }

    private String safeLimit(Integer max) {
        Integer n = (max == null || max <= 0) ? 50000 : max;
        return String.valueOf(n);
    }
}