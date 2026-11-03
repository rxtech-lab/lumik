import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { z } from 'zod';
import { agentTools, proposeDocumentAnalysis } from '@/lib/ai';
import { authenticateOAuthToken } from '@/lib/mcp/oauth-tokens';
import { getDatabase } from '@/lib/mcp/database';
import { authChallenge, toolScope } from '@/lib/mcp/oauth-config';
import { ApiError } from '@/lib/contracts';
import { Repository } from '@/lib/repository';
import { mutationInput } from '@/lib/contracts';
import { errorResponse } from '@/lib/http';
export const runtime = 'nodejs';
export const maxDuration = 120;
export async function POST(request: Request) {
    try {
        const token = request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
        const identity = token ? await authenticateOAuthToken(getDatabase(), token) : null;
        if (!identity) throw new ApiError(401, 'Sign in to Lumik to connect this client');
        const repo = new Repository(identity.sub);
        const server = new McpServer({ name: 'lumik', version: '0.1.0' });
        const register = (name: string, config: { description: string; inputSchema: z.ZodRawShape }, callback: (input: any) => Promise<any>) => {
            const scope = toolScope(name);
            server.registerTool(name, { ...config, _meta: { securitySchemes: [{ type: 'oauth2', scopes: [scope] }] } }, async (input: any) => {
                if (!identity.scopes.includes(scope)) return { isError: true, content: [{ type: 'text' as const, text: 'Approve the required permission to use this tool.' }], _meta: { 'mcp/www_authenticate': [authChallenge(scope, 'insufficient_scope')] } };
                return callback(input);
            });
        };
        const content = (value: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value) }] });
        register('list_groups', { description: 'List your document groups', inputSchema: {} }, async () => content(await repo.groups()));
        register('list_documents', { description: 'Read document metadata and extracted fields', inputSchema: { groupId: z.string() } }, async ({ groupId }) => content(await repo.documents(groupId)));
        register('analyze_document', {description:'Analyze a PDF and propose extracted fields and a filename for user review',inputSchema:{documentId:z.string()}},async({documentId})=>content(await proposeDocumentAnalysis(repo,documentId)));
        register('propose_change', { description: 'Prepare a change for user review in Lumik. Does not apply changes.', inputSchema: { mutation: mutationInput } }, async ({ mutation }) => content(await repo.propose(mutation)));
        const tools = agentTools(repo);
        for (const name of ['create_upload', 'complete_upload', 'get_pdf', 'get_summary', 'get_statistics', 'write_statistics', 'move_document', 'rename_document', 'read_pdf', 'run_js', 'run_sql', 'list_views'] as const) {
            const definition = tools[name];
            register(name, { description: definition.description as string, inputSchema: (definition.inputSchema as z.ZodObject).shape }, async (input: unknown) => content(await (definition.execute as (input: unknown, options: unknown) => Promise<unknown>)(input, {})));
        }
        register('list_proposals', { description: 'List pending changes awaiting approval in the app', inputSchema: {} }, async () => content(await repo.proposals()));
        const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
        await server.connect(transport);
        return await transport.handleRequest(request);
    }
    catch (e) {
        const response = errorResponse(e);
        if (response.status === 401) response.headers.set('WWW-Authenticate', authChallenge('lumik:read', 'invalid_token'));
        return response;
    }
}

export async function GET(request: Request) {
    try {
        const token = request.headers.get('authorization')?.match(/^Bearer (.+)$/i)?.[1];
        if (!token || !await authenticateOAuthToken(getDatabase(), token)) {
            return Response.json({ error: 'Sign in to Lumik' }, { status: 401, headers: { 'WWW-Authenticate': authChallenge('lumik:read') } });
        }
        return new Response(null, { status: 405, headers: { Allow: 'POST' } });
    } catch (e) { return errorResponse(e); }
}
