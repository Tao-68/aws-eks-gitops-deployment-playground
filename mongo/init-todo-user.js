db.getSiblingDB('todos').createUser({
  user: process.env.TODO_DB_USER,
  pwd: process.env.TODO_DB_PASSWORD,
  roles: [{ role: 'readWrite', db: 'todos' }],
});