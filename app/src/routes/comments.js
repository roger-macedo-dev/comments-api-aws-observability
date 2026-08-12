const express = require('express');
const pool = require('../db/pool');

const router = express.Router();

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

router.post('/comment/new', async (req, res) => {
  const { email, comment, content_id: contentId } = req.body;

  if (!email || !EMAIL_RE.test(email)) {
    return res.status(400).json({ error: 'email inválido' });
  }
  if (!comment || typeof comment !== 'string' || comment.trim() === '') {
    return res.status(400).json({ error: 'comment não pode ser vazio' });
  }
  if (!Number.isInteger(contentId) || contentId <= 0) {
    return res.status(400).json({ error: 'content_id deve ser inteiro positivo' });
  }

  try {
    const result = await pool.query(
      `INSERT INTO comments (email, comment, content_id)
       VALUES ($1, $2, $3)
       RETURNING id, email, comment, content_id, created_at`,
      [email, comment, contentId]
    );
    res.status(201).json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'erro ao salvar comentário' });
  }
});

router.get('/comment/list/:contentId', async (req, res) => {
  const contentId = Number(req.params.contentId);

  if (!Number.isInteger(contentId) || contentId <= 0) {
    return res.status(400).json({ error: 'content_id deve ser inteiro positivo' });
  }

  try {
    const result = await pool.query(
      `SELECT id, email, comment, content_id, created_at
       FROM comments
       WHERE content_id = $1
       ORDER BY created_at ASC`,
      [contentId]
    );
    res.status(200).json(result.rows);
  } catch (err) {
    res.status(500).json({ error: 'erro ao listar comentários' });
  }
});

module.exports = router;
