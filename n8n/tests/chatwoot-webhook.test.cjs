const { test } = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const base = path.resolve(__dirname, '..');
const workflowRoot = path.join(base, 'workflows');
const webhook = JSON.parse(fs.readFileSync(path.join(workflowRoot, 'Infraestrutura - Chatwoot/Webhook Chatwoot - Elo Connect.json'), 'utf8'));
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const env = {
  N8N_CHATWOOT_WEBHOOK_SECRET: 'test-only-secret',
  N8N_CHATWOOT_ACCOUNT_ID: '1',
  N8N_CHATWOOT_INBOX_IDS: '7,8',
  N8N_CHATWOOT_BASE_URL: 'https://chatbot.kohesa.com.br',
  N8N_CHATWOOT_API_TOKEN: 'test-only-token',
  N8N_WHATSAPP_BUSINESS_PHONE_NUMBER: '5511000000000',
};

function fixture(channel = 'Channel::WebWidget') {
  return {
    account: { id: 1 },
    inbox: { id: 7 },
    id: 44,
    event: 'message_created',
    message_type: 'incoming',
    private: false,
    content_type: 'text',
    content: 'Quero encontrar um eletricista',
    created_at: '2026-10-08T12:00:00.000Z',
    sender: { id: 91, name: 'Contato de teste', phone_number: null },
    conversation: {
      id: 123,
      account_id: 1,
      inbox_id: 7,
      channel,
      status: 'open',
      contact_inbox: { source_id: 'widget-contact-91' },
      meta: { sender: { id: 91, name: 'Contato de teste', phone_number: null }, assignee: null },
    },
  };
}

async function runCode(name, { item = { json: {} }, outputs = {}, variables = env, raw, missingRaw = false } = {}) {
  const code = webhook.nodes.find((node) => node.name === name).parameters.jsCode;
  const input = { first: () => item, all: () => [item] };
  const lookup = (key) => ({ first: () => ({ json: outputs[key] }), item: { json: outputs[key] } });
  const fn = new AsyncFunction('$input', '$json', '$env', '$', 'require', 'Buffer', code);
  const result = await fn.call({ helpers: { getBinaryDataBuffer: async () => {
    if (missingRaw) throw new Error('missing');
    return raw;
  } } }, input, item.json, variables, lookup, require, Buffer);
  return Array.isArray(result) ? result : [{ json: result }];
}

function signed(body = fixture(), timestamp = String(Math.floor(Date.now() / 1000))) {
  const raw = Buffer.from(JSON.stringify(body));
  const digest = crypto.createHmac('sha256', env.N8N_CHATWOOT_WEBHOOK_SECRET)
    .update(timestamp + '.').update(raw).digest('hex');
  return {
    raw,
    item: { json: { headers: {
      'x-chatwoot-timestamp': timestamp,
      'x-chatwoot-signature': 'sha256=' + digest,
    } } },
  };
}

const normalize = (body, variables = env) => runCode('Normalizar evento Chatwoot', {
  outputs: { 'validar assinatura': { body } }, variables,
});

function walk(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) =>
    entry.isDirectory() ? walk(path.join(dir, entry.name)) : [path.join(dir, entry.name)]
  );
}

test('valida a assinatura Chatwoot sobre o corpo bruto e rejeita adulteração', async () => {
  const request = signed();
  assert.equal((await runCode('validar assinatura', request))[0].json.valid, true);
  request.raw = Buffer.concat([request.raw, Buffer.from(' ')]);
  assert.equal((await runCode('validar assinatura', request))[0].json.valid, false);
});

test('falha fechada sem segredo, assinatura, timestamp atual ou corpo bruto', async () => {
  const request = signed();
  assert.equal((await runCode('validar assinatura', { ...request, variables: {} }))[0].json.http_status, 503);
  delete request.item.json.headers['x-chatwoot-signature'];
  assert.equal((await runCode('validar assinatura', request))[0].json.http_status, 401);
  const old = signed(fixture(), String(Math.floor(Date.now() / 1000) - 600));
  assert.equal((await runCode('validar assinatura', old))[0].json.valid, false);
  assert.equal((await runCode('validar assinatura', { ...signed(), missingRaw: true }))[0].json.http_status, 503);
});

test('normaliza mensagens do widget com identidade estável e IDs da conversa', async () => {
  const [result] = await normalize(fixture());
  assert.equal(result.json.tipo_evento, 'mensagem');
  assert.equal(result.json.account_id, 1);
  assert.equal(result.json.inbox_id, 7);
  assert.equal(result.json.conversation_id, 123);
  assert.equal(result.json.canal, 'Channel::WebWidget');
  assert.equal(result.json.wa_user_id, 'chatwoot_1_7_widget-contact-91');
  assert.equal(result.json.telefone, null);
  assert.equal(result.json.mensagem_id, 'chatwoot_1_123_44');
  assert.equal(result.json.texto, 'Quero encontrar um eletricista');
});

test('normaliza WhatsApp pelo mesmo contrato e preserva o source_id', async () => {
  const body = fixture('Channel::Whatsapp');
  body.source_id = 'wamid.test.incoming';
  body.sender.phone_number = '+55 (11) 99999-9999';
  body.conversation.meta.sender.phone_number = '+55 (11) 99999-9999';
  const [result] = await normalize(body);
  assert.equal(result.json.tipo_evento, 'mensagem');
  assert.equal(result.json.telefone, '5511999999999');
  assert.equal(result.json.wa_user_id, 'chatwoot_1_7_widget-contact-91');
  assert.equal(result.json.mensagem_id, 'wamid.test.incoming');
});

test('message_updated de saída atualiza o status pelo ID persistido do Chatwoot', async () => {
  const body = fixture();
  body.id = 777;
  body.event = 'message_updated';
  body.message_type = 'outgoing';
  body.status = 'delivered';
  body.sender = { id: 5, name: 'Elo - PMC', type: 'agent_bot' };
  const [result] = await normalize(body);
  assert.equal(result.json.tipo_evento, 'status');
  assert.equal(result.json.status, 'delivered');
  assert.equal(result.json.mensagem_persistencia_id, '777');
  assert.equal(result.json.wa_user_id, 'chatwoot_1_7_widget-contact-91');
});

test('ignora saída, nota privada, outros eventos, contas, inboxes e canais', async () => {
  const changes = [
    { message_type: 'outgoing' },
    { private: true },
    { event: 'conversation_updated' },
    { account: { id: 2 } },
    { inbox: { id: 99 }, conversation: { ...fixture().conversation, inbox_id: 99 } },
    { conversation: { ...fixture().conversation, channel: 'Channel::Email' } },
  ];
  for (const change of changes) assert.deepEqual(await normalize({ ...fixture(), ...change }), []);
});

test('anexos, conteúdo estruturado e texto vazio são recusados antes da IA', async () => {
  for (const change of [
    { attachments: [{ id: 1, file_type: 'image' }] },
    { content_type: 'input_select' },
    { content: '   ' },
  ]) {
    const [result] = await normalize({ ...fixture(), ...change });
    assert.equal(result.json.tipo_evento, 'nao_suportado');
    assert.equal(result.json.tipo_mensagem, 'unsupported');
    assert.equal(result.json.media_url, '');
  }
});

test('webhook e saídas usam somente o contrato Chatwoot', () => {
  const hook = webhook.nodes.find((node) => node.name === 'Webhook Chatwoot');
  assert.equal(hook.parameters.path, 'chatwoot/elo');
  assert.equal(hook.parameters.options.rawBody, true);
  const serialized = JSON.stringify(webhook);
  assert.ok(!/callbell/i.test(serialized));
  assert.equal(webhook.connections['Normalizar evento Chatwoot'].main[0][0].node, 'If - Evento de status?');
  assert.equal(webhook.connections['If - Evento de status?'].main[0][0].node, 'Formatar dados');
  assert.equal(webhook.connections['If - Evento de status?'].main[1][0].node, 'If - Mensagem recebida?');

  let sends = 0;
  for (const file of walk(workflowRoot).filter((name) => name.endsWith('.json'))) {
    const workflow = JSON.parse(fs.readFileSync(file, 'utf8'));
    for (const node of workflow.nodes) {
      const url = String(node.parameters?.url || '');
      if (!url.includes('/conversations/')) continue;
      sends += 1;
      assert.match(url, /N8N_CHATWOOT_BASE_URL/);
      assert.match(url, /account_id/);
      assert.match(url, /conversation_id/);
      const headers = JSON.stringify(node.parameters.headerParameters);
      assert.match(headers, /N8N_CHATWOOT_API_TOKEN/);
      assert.match(headers, /api_access_token/);
      assert.doesNotMatch(headers, /Authorization|Bearer/);
      assert.match(node.parameters.jsonBody, /"message_type": "outgoing"/);
      assert.match(node.parameters.jsonBody, /"content_type": "text"/);
    }
  }
  assert.ok(sends > 0, 'nenhum nó de envio ao Chatwoot foi encontrado');
});

test('todos os workflows têm código compilável e arestas válidas', () => {
  for (const file of walk(workflowRoot).filter((name) => name.endsWith('.json'))) {
    const workflow = JSON.parse(fs.readFileSync(file, 'utf8'));
    const names = new Set(workflow.nodes.map((node) => node.name));
    assert.equal(names.size, workflow.nodes.length, file);
    for (const node of workflow.nodes) if (node.parameters?.jsCode) new AsyncFunction(node.parameters.jsCode);
    for (const [source, outputTypes] of Object.entries(workflow.connections || {})) {
      assert.ok(names.has(source), `${file}: origem inexistente ${source}`);
      for (const branches of Object.values(outputTypes)) {
        for (const branch of branches) for (const edge of branch) {
          assert.ok(names.has(edge.node), `${file}: destino inexistente ${edge.node}`);
        }
      }
    }
  }
});

