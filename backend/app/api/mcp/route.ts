import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { WebStandardStreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js';
import { z } from 'zod';
import { proposeDocumentAnalysis } from '@/lib/ai';
import { principal } from '@/lib/auth';
import { Repository } from '@/lib/repository';
import { mutationInput } from '@/lib/contracts';
import { errorResponse } from '@/lib/http';
export const runtime = 'nodejs';
export const maxDuration = 120;
export async function POST(request: Request) {
    try {
        const repo = new Repository(await principal(request));
        const server = new McpServer({ name: 'scanner-buddy', version: '0.1.0' });
        const content = (value: unknown) => ({ content: [{ type: 'text' as const, text: JSON.stringify(value) }] });
        server.registerTool('list_groups', { description: 'List your document groups', inputSchema: {} }, async () => content(await repo.groups()));
        server.registerTool('list_documents', { description: 'Read document metadata and extracted fields', inputSchema: { groupId: z.string() } }, async ({ groupId }) => content(await repo.documents(groupId)));
        server.registerTool('analyze_document', {description:'Analyze a PDF and propose extracted fields and a filename for user review',inputSchema:{documentId:z.string()}},async({documentId})=>content(await proposeDocumentAnalysis(repo,documentId)));
        server.registerTool('propose_change', { description: 'Prepare a change for user review in Scanner Buddy. Does not apply changes.', inputSchema: { mutation: mutationInput } }, async ({ mutation }) => content(await repo.propose(mutation)));
        server.registerTool('list_proposals', { description: 'List pending changes awaiting approval in the app', inputSchema: {} }, async () => content(await repo.proposals()));
        const transport = new WebStandardStreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
        await server.connect(transport);
        return await transport.handleRequest(request);
    }
    catch (e) {
        return errorResponse(e);
    }
}
