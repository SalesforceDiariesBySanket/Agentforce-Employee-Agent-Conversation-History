import { LightningElement, api, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { open as accOpen, execute as accExecute } from 'lightning/accApi';
import getFilterOptions from '@salesforce/apex/AgentSessionController.getFilterOptions';
import getSessionPage from '@salesforce/apex/AgentSessionController.getSessionPage';
import getConversation from '@salesforce/apex/AgentSessionController.getConversation';
import getEarlierMessages from '@salesforce/apex/AgentSessionController.getEarlierMessages';
import getAllMessages from '@salesforce/apex/AgentSessionController.getAllMessages';

const MESSAGE_PAGE_SIZE = 10;

export default class AgentSessionViewer extends LightningElement {
    // Reserved design attribute; kept because the platform refuses to drop a property in use on a page.
    // Currently unused by the component logic.
    @api targetUserId;

    // ---- Filter state ----------------------------------------------------
    @track agentOptions = [];
    hasAssignedAgents = false;
    selectedAgent = '';

    // ---- Session list (left pane) ---------------------------------------
    @track sessions = [];
    nextOffset = null;
    hasMore = false;
    totalSessions = null;
    listLoading = false;

    // ---- Conversation (right pane) --------------------------------------
    @track messages = [];
    selectedSessionId = null;
    selectedAgentApiName = null;
    selectedUserId = null;
    selectedUserName = null;
    botId = null;
    detailLoading = false;
    continuing = false;
    totalMessages = 0;
    hasEarlierMessages = false;
    loadingEarlier = false;

    connectedCallback() {
        this.loadFilterOptions();
        this.loadFirstPage();
    }

    async loadFilterOptions() {
        try {
            const data = await getFilterOptions();
            this.agentOptions = [{ label: 'All my agents', value: '' }, ...(data.myAgents || [])];
            this.hasAssignedAgents = data.hasAssignedAgents;
        } catch (e) {
            this.toastError('Could not load agent options', e);
        }
    }

    // ---- Session list ----------------------------------------------------

    _loadToken = 0;

    async loadFirstPage() {
        this.sessions = [];
        this.nextOffset = null;
        this.hasMore = false;
        this.totalSessions = null;
        await this.loadPage(0);
    }

    async loadPage(offset) {
        const token = ++this._loadToken;
        this.listLoading = true;
        try {
            const page = await getSessionPage({
                agentApiName: this.selectedAgent || '',
                offset
            });
            if (token !== this._loadToken) {
                return;
            }
            const rows = (page.sessions || []).map((s) => this.decorateSession(s));
            this.sessions = offset > 0 ? [...this.sessions, ...rows] : rows;
            this.nextOffset = page.nextOffset;
            this.hasMore = page.hasMore;
            this.totalSessions = page.totalSessions;
        } catch (e) {
            if (token === this._loadToken) {
                this.toastError('Could not load sessions', e);
            }
        } finally {
            if (token === this._loadToken) {
                this.listLoading = false;
            }
        }
    }

    decorateSession(s) {
        return {
            ...s,
            cssClass:
                s.sessionId === this.selectedSessionId
                    ? 'session-row session-row_selected'
                    : 'session-row',
            label: s.agentApiName || 'Unknown agent',
            initial: (s.agentApiName || '?').charAt(0).toUpperCase(),
            sub: s.userName || s.userParticipantId || 'No user',
            countLabel: `${s.messageCount} msg${s.messageCount === 1 ? '' : 's'}`,
            relativeTime: this.relativeTime(s.startTime)
        };
    }

    // ---- Filter handlers -------------------------------------------------

    handleAgentChange(event) {
        this.selectedAgent = event.detail.value;
        this.loadFirstPage();
    }

    handleLoadMore() {
        if (this.nextOffset != null) {
            this.loadPage(this.nextOffset);
        }
    }

    get showAgentDropdown() {
        return this.agentOptions && this.agentOptions.length > 0;
    }

    get sessionCountLabel() {
        if (this.totalSessions === null) {
            return '';
        }
        const n = this.totalSessions;
        return `${n} session${n === 1 ? '' : 's'}`;
    }

    get noSessions() {
        return !this.listLoading && this.sessions.length === 0;
    }

    // ---- Conversation detail --------------------------------------------

    async handleSelectSession(event) {
        const sessionId = event.currentTarget.dataset.id;
        if (!sessionId || sessionId === this.selectedSessionId) {
            return;
        }
        this.selectedSessionId = sessionId;
        this.sessions = this.sessions.map((s) => ({
            ...s,
            cssClass:
                s.sessionId === sessionId ? 'session-row session-row_selected' : 'session-row'
        }));
        await this.loadConversation(sessionId);
    }

    async loadConversation(sessionId) {
        this.detailLoading = true;
        this.messages = [];
        this.totalMessages = 0;
        this.hasEarlierMessages = false;
        try {
            const detail = await getConversation({ sessionId });
            this.selectedAgentApiName = detail.agentApiName;
            this.selectedUserId = detail.userParticipantId;
            this.selectedUserName = detail.userName || detail.userParticipantId;
            this.botId = detail.botId;
            this.totalMessages = detail.totalMessages;
            this.hasEarlierMessages = detail.hasEarlier;
            this.messages = (detail.messages || []).map((m, i) => this.decorateMessage(m, i));
        } catch (e) {
            this.toastError('Could not load conversation', e);
        } finally {
            this.detailLoading = false;
        }
    }

    async handleLoadEarlier() {
        if (!this.selectedSessionId || this.loadingEarlier || !this.hasEarlierMessages) {
            return;
        }
        const sessionId = this.selectedSessionId;
        this.loadingEarlier = true;
        try {
            const page = await getEarlierMessages({
                sessionId,
                loadedCount: this.messages.length,
                pageSize: MESSAGE_PAGE_SIZE
            });
            if (sessionId !== this.selectedSessionId) {
                return;
            }
            const older = (page.messages || []).map((m, i) =>
                this.decorateMessage(m, `e${this.messages.length}_${i}`)
            );
            this.messages = [...older, ...this.messages];
            this.hasEarlierMessages = page.hasEarlier;
        } catch (e) {
            this.toastError('Could not load earlier messages', e);
        } finally {
            this.loadingEarlier = false;
        }
    }

    decorateMessage(m, i) {
        return {
            ...m,
            key: m.id || `m${i}`,
            bubbleClass: m.fromUser ? 'msg msg_user' : 'msg msg_agent',
            who: m.fromUser ? m.participantId || 'User' : m.participantObject || 'Agent'
        };
    }

    get hasSelection() {
        return !!this.selectedSessionId;
    }

    get noMessages() {
        return this.hasSelection && !this.detailLoading && this.messages.length === 0;
    }

    get showLoadEarlier() {
        return this.hasSelection && !this.detailLoading && this.hasEarlierMessages;
    }

    get earlierLabel() {
        const remaining = Math.max(this.totalMessages - this.messages.length, 0);
        return remaining > 0 ? `Load earlier messages (${remaining})` : 'Load earlier messages';
    }

    get canContinue() {
        return this.hasSelection && !!this.botId;
    }

    get continueDisabled() {
        return !this.canContinue || this.continuing;
    }

    // ---- Continue (lightning/accApi) ------------------------------------
    SEED_CHAR_BUDGET = 3500;

    async handleContinue() {
        if (!this.canContinue) {
            return;
        }
        this.continuing = true;
        try {
            const all = await getAllMessages({ sessionId: this.selectedSessionId });
            await accOpen(this.botId);
            await accExecute(this.buildContinuationSeed(all), this.botId);
            this.toast(
                'Continued in Agentforce',
                'Opened the agent panel and sent the prior conversation as context.',
                'success'
            );
        } catch (e) {
            this.toastError('Could not open Agentforce', e);
        } finally {
            this.continuing = false;
        }
    }

    buildContinuationSeed(allMessages) {
        const source = allMessages || this.messages || [];
        const lines = source
            .filter((m) => m.text && m.text.trim())
            .map((m) => `${m.fromUser ? 'User' : 'Agent'}: ${m.text.trim()}`);

        if (lines.length === 0) {
            return 'Continuing our earlier conversation. Please pick up where we left off.';
        }

        let truncated = false;
        while (lines.join('\n').length > this.SEED_CHAR_BUDGET && lines.length > 1) {
            lines.shift();
            truncated = true;
        }

        const preamble = truncated
            ? 'Here is the most recent part of our earlier conversation (older messages omitted). Please use it as context and continue from where we left off:'
            : 'Here is our earlier conversation. Please use it as context and continue from where we left off:';

        return `${preamble}\n\n${lines.join('\n')}`;
    }

    // ---- utils -----------------------------------------------------------

    relativeTime(value) {
        if (!value) {
            return '';
        }
        const then = new Date(value).getTime();
        if (isNaN(then)) {
            return '';
        }
        const diff = Date.now() - then;
        const min = Math.floor(diff / 60000);
        if (min < 1) {
            return 'just now';
        }
        if (min < 60) {
            return `${min}m ago`;
        }
        const hr = Math.floor(min / 60);
        if (hr < 24) {
            return `${hr}h ago`;
        }
        const day = Math.floor(hr / 24);
        if (day < 30) {
            return `${day}d ago`;
        }
        return new Date(value).toLocaleDateString();
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    toastError(title, e) {
        const message = (e && e.body && e.body.message) || (e && e.message) || 'Unknown error';
        this.toast(title, message, 'error');
    }
}