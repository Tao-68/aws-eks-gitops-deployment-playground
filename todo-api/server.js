const express = require('express');
const mongoose = require('mongoose');
const app = express();
const port = process.env.PORT || 3001;
const host = process.env.HOST || '127.0.0.1';

const todoSchema = new mongoose.Schema(
  {
    title: { type: String, required: true, trim: true },
    completed: { type: Boolean, default: false },
  },
  { timestamps: true }
);
const Todo = mongoose.model('Todo', todoSchema);

app.use(express.json())

app.get('/todos', async (req, res) => {
  const todos = await Todo.find();
  res.json(todos);
});

app.post('/todos', async (req, res) => {
  const { title, completed } = req.body ?? {};
  const todo = await Todo.create({ title, completed });
  res.status(201).json(todo);
});

app.get('/todos/:id', async (req, res) => {
  const todo = await Todo.findById(req.params.id);
  if (!todo) return res.status(404).json({ error: 'Todo not found' });
  res.json(todo);
});

app.put('/todos/:id', async (req, res) => {
  const { title, completed } = req.body ?? {};
  const todo = await Todo.findByIdAndUpdate(
    req.params.id,
    { title, completed },
    { returnDocument: 'after', runValidators: true }
  );
  if (!todo) return res.status(404).json({ error: 'Todo not found' });
  res.json(todo);
});

app.delete('/todos/:id', async (req, res) => {
  const todo = await Todo.findByIdAndDelete(req.params.id);
  if (!todo) return res.status(404).json({ error: 'Todo not found' });
  res.status(204).end();
});

app.get('/health', (req, res) => {
  if (mongoose.connection.readyState === 1) return res.json({ status: 'ok' });
  res.status(503).json({ status: 'database unavailable' });
});

app.use((err, req, res, next) => {
  if (err.name === 'ValidationError') {
    return res.status(400).json({ error: err.message });
  }
  if (err.name === 'CastError') {
    return res.status(400).json({ error: 'Invalid id' });
  }
  if (err.type === 'entity.parse.failed') {
    return res.status(400).json({ error: 'Invalid JSON' });
  }
  console.error(err);
  res.status(500).json({ error: 'Internal server error' });
});

async function start() {
  try {
    await mongoose.connect(process.env.MONGODB_URI);
  } catch (err) {
    console.error('Could not connect to MongoDB:', err.message);
    process.exit(1);
  }
  app.listen(port, host, () => {
    console.log(`Todo API listening on http://${host}:${port}`);
  });
}

start();