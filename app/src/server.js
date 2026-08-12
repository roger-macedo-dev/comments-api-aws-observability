require('dotenv').config();
const express = require('express');

const healthRouter = require('./routes/health');
const commentsRouter = require('./routes/comments');
const { register, metricsMiddleware } = require('./metrics');

const app = express();
const PORT = process.env.PORT || 5000;

app.use(express.json());
app.use(metricsMiddleware);

app.use('/', healthRouter);
app.use('/api', commentsRouter);

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

if (require.main === module) {
  app.listen(PORT, () => {
    console.log(`comments-api rodando na porta ${PORT}`);
  });
}

module.exports = app;
