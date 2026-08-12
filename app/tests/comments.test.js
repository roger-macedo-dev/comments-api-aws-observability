const request = require('supertest');
const app = require('../src/server');
const pool = require('../src/db/pool');
const migrate = require('../src/db/migrate');

beforeAll(async () => {
  await migrate();
});

afterAll(async () => {
  await pool.query('DELETE FROM comments');
  await pool.end();
});

describe('POST /api/comment/new', () => {
  it('cria um comentário válido', async () => {
    const res = await request(app)
      .post('/api/comment/new')
      .send({ email: 'alice@example.com', comment: 'first post!', content_id: 1 });

    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({
      email: 'alice@example.com',
      comment: 'first post!',
      content_id: 1,
    });
    expect(res.body.id).toBeDefined();
  });

  it('rejeita email inválido', async () => {
    const res = await request(app)
      .post('/api/comment/new')
      .send({ email: 'nao-e-email', comment: 'oi', content_id: 1 });

    expect(res.status).toBe(400);
  });

  it('rejeita comment vazio', async () => {
    const res = await request(app)
      .post('/api/comment/new')
      .send({ email: 'bob@example.com', comment: '', content_id: 1 });

    expect(res.status).toBe(400);
  });

  it('rejeita content_id não-inteiro', async () => {
    const res = await request(app)
      .post('/api/comment/new')
      .send({ email: 'bob@example.com', comment: 'oi', content_id: 'abc' });

    expect(res.status).toBe(400);
  });
});

describe('GET /api/comment/list/:contentId', () => {
  it('lista comentários da matéria em ordem cronológica', async () => {
    await request(app)
      .post('/api/comment/new')
      .send({ email: 'alice@example.com', comment: 'msg 1', content_id: 2 });
    await request(app)
      .post('/api/comment/new')
      .send({ email: 'bob@example.com', comment: 'msg 2', content_id: 2 });

    const res = await request(app).get('/api/comment/list/2');

    expect(res.status).toBe(200);
    expect(res.body).toHaveLength(2);
    expect(res.body[0].comment).toBe('msg 1');
    expect(res.body[1].comment).toBe('msg 2');
  });

  it('retorna lista vazia pra matéria sem comentários', async () => {
    const res = await request(app).get('/api/comment/list/999');
    expect(res.status).toBe(200);
    expect(res.body).toEqual([]);
  });

  it('rejeita content_id inválido na URL', async () => {
    const res = await request(app).get('/api/comment/list/abc');
    expect(res.status).toBe(400);
  });
});
