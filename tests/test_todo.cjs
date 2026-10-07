const { readFileSync } = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const todo = vm.createContext({});
vm.runInContext(readFileSync(require('node:path').join(__dirname, '../Todo.js'), 'utf8'), todo);

test('separates metadata while preserving the complete editable line', () => {
  const raw = '  (A) 2026-09-09 Review paper +cubo @work due:2026-09-10 rec:1w custom:yes  ';
  const task = todo.parseLine(raw);
  assert.equal(task.rawText, raw);
  assert.equal(task.displayText, 'Review paper');
  assert.equal(task.priority, 'A');
  assert.equal(task.due, '2026-09-10');
  assert.equal(task.metadata.join(' '), 'due:2026-09-10 rec:1w custom:yes');
});

test('recognizes leading tags and metadata, keeps URLs and ordinary punctuation', () => {
  assert.equal(todo.parseLine('+cubo custom:yes @work Read https://example.org Note: today').displayText,
    'Read https://example.org Note: today');
  assert.equal(todo.parseLine('custom:yes +cubo @work').displayText, '');
  const quoted = todo.parseLine('Read book +books author:"Brandon Sanderson" details:"a:b value"');
  assert.equal(quoted.displayText, 'Read book');
  assert.equal(quoted.metadata.join('|'), 'author:"Brandon Sanderson"|details:"a:b value"');
});

test('parses archived tasks without completion bookkeeping in the title', () => {
  const task = todo.parseCompletedLine(
    'x 2025-12-31 2025-01-01 Ler livro: Skyward +livros @lido autor:"Brandon Sanderson"');
  assert.equal(task.displayText, 'Ler livro: Skyward');
  assert.equal(task.completed, true);
  assert.equal(task.completedDate, '2025-12-31');
  assert.equal(task.projects.join(' '), 'livros');
  assert.equal(task.contexts.join(' '), 'lido');
  assert.equal(todo.matchesSearch(task, 'brandon @lido'), true);
  assert.equal(todo.matchesSearch(task, 'skyw @lido'), true);
});

test('counts each task once per tag, including object prototype names', () => {
  const tasks = ['One +cubo +cubo @work', 'Two +cubo +__proto__ @work', 'Three +constructor'].map(todo.parseLine);
  const counts = todo.counts(tasks, 'projects');
  assert.equal(counts.cubo, 2);
  assert.equal(counts.__proto__, 1);
  assert.equal(counts.constructor, 1);
  assert.equal(todo.counts(tasks, 'contexts').work, 2);
});

test('filters completed activity by project or context facets', () => {
  const tasks = [
    todo.parseCompletedLine('x 2026-09-20 Read +books @home'),
    todo.parseCompletedLine('x 2026-09-21 Review +work @office'),
    todo.parseCompletedLine('x 2026-09-22 Write +books @office')
  ];
  assert.deepEqual(Array.from(todo.filterByFacet(tasks, 'project', 'books'), task => task.displayText),
    ['Read', 'Write']);
  assert.deepEqual(Array.from(todo.filterByFacet(tasks, 'context', 'office'), task => task.displayText),
    ['Review', 'Write']);
  assert.equal(todo.filterByFacet(tasks, 'all', ''), tasks);
});

test('builds a Sunday-aligned 13-week completion heatmap', () => {
  const tasks = [
    { completedDate: '2026-09-20' },
    { completedDate: '2026-09-20' },
    { completedDate: '2026-09-21' },
    { completedDate: '2026-06-01' },
    { completedDate: 'invalid' }
  ];
  const heatmap = todo.completionHeatmap(tasks, '2026-09-22', 13);
  assert.equal(heatmap.cells.length, 91);
  assert.equal(heatmap.startDate, '2026-06-28');
  assert.equal(heatmap.endDate, '2026-09-22');
  assert.equal(heatmap.total, 3);
  assert.deepEqual(Array.from(heatmap.monthLabels.filter(Boolean)), ['Jul', 'Aug', 'Sep']);
  assert.deepEqual(
    Array.from(heatmap.cells.slice(-7), cell => [cell.date, cell.count, cell.level, cell.future]),
    [
      ['2026-09-20', 2, 2, false],
      ['2026-09-21', 1, 1, false],
      ['2026-09-22', 0, 0, false],
      ['2026-09-23', 0, 0, true],
      ['2026-09-24', 0, 0, true],
      ['2026-09-25', 0, 0, true],
      ['2026-09-26', 0, 0, true]
    ]
  );
});

test('labels the months represented by heatmap week columns', () => {
  const heatmap = todo.completionHeatmap([], '2026-09-22', 26);
  assert.equal(heatmap.cells.length, 182);
  assert.equal(heatmap.monthLabels.length, 26);
  assert.deepEqual(Array.from(heatmap.monthLabels.filter(Boolean)),
    ['Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep']);
});

test('caps heatmap intensity at four completed tasks', () => {
  const tasks = Array.from({ length: 7 }, () => ({ completedDate: '2026-09-22' }));
  const cell = todo.completionHeatmap(tasks, '2026-09-22', 1).cells[2];
  assert.equal(cell.count, 7);
  assert.equal(cell.level, 4);
});

test('ranks completed projects within the heatmap period', () => {
  const tasks = [
    todo.parseCompletedLine('x 2026-09-20 Read +books +leisure'),
    todo.parseCompletedLine('x 2026-09-21 Write +books'),
    todo.parseCompletedLine('x 2026-09-22 Review +work'),
    todo.parseCompletedLine('x 2026-09-22 Plan +admin'),
    todo.parseCompletedLine('x 2026-01-01 Old +books')
  ];
  assert.deepEqual(Array.from(todo.topCompletedFacets(tasks, 'projects', '2026-04-01', '2026-09-22', 3),
    item => [item.name, item.count]), [['books', 2], ['admin', 1], ['leisure', 1]]);
});

test('fuzzy search matches text, projects and contexts with AND semantics', () => {
  const task = todo.parseLine('Prepare quarterly invoice +EditoraCubo @DeepWork due:2026-09-30');
  assert.equal(todo.matchesSearch(task, 'prep invc'), true);
  assert.equal(todo.matchesSearch(task, '+cubo @dwork'), true);
  assert.equal(todo.matchesSearch(task, 'invc +edcbo @deep'), true);
  assert.equal(todo.matchesSearch(task, 'invoice +other'), false);
  assert.equal(todo.matchesSearch(task, '@office'), false);
  assert.equal(todo.matchesSearch(task, ''), true);
});

test('plain search terms match the complete task including metadata', () => {
  const task = todo.parseLine('Prepare invoice +EditoraCubo @DeepWork custom:quarterly');
  assert.equal(todo.matchesSearch(task, 'EditoraCubo'), true);
  assert.equal(todo.matchesSearch(task, 'DeepWork'), true);
  assert.equal(todo.matchesSearch(task, 'quarterly'), true);
  assert.equal(todo.matchesSearch(task, '+EditoraCubo'), true);
  assert.equal(todo.matchesSearch(task, '@DeepWork'), true);
  assert.equal(todo.matchesSearch(todo.parseLine('Blood of Dragons author:"Robin Hobb"'), 'brandon'), false);
});

test('search scopes are ignored as terms and the last recognized scope wins', () => {
  const task = todo.parseLine('Pay invoice +finance rec:1m');
  assert.equal(todo.matchesSearch(task, 'invoice in:done'), true);
  assert.equal(todo.searchScope('invoice'), 'open');
  assert.equal(todo.searchScope('invoice in:all'), 'all');
  assert.equal(todo.searchScope('in:done invoice in:rec'), 'rec');
  assert.equal(todo.searchScope('invoice in:unknown'), 'open');
  assert.equal(todo.isRecurring(task), true);
  assert.equal(todo.isRecurring(todo.parseLine('Pay invoice +finance')), false);
  assert.equal(todo.withSearchScope('brandon @lido in:all', 'done'), 'brandon @lido in:done');
  assert.equal(todo.withSearchScope('in:due invoice in:rec', 'open'), 'invoice');
  assert.equal(todo.withSearchScope('invoice', 'all'), 'invoice in:all');
});

test('escapes task-supplied markup before rendering colored metadata', () => {
  const html = todo.metadataHtml(todo.parseLine('Title +<img> @a&b custom:<b>'), '#888888', '#aa5555');
  assert.ok(html.includes('+&lt;img&gt;'));
  assert.ok(html.includes('@a&amp;b'));
  assert.ok(html.includes('custom:&lt;b&gt;'));
  assert.ok(html.includes('<font color="#aa5555">@a&amp;b</font>'));
  assert.equal((html.match(/</g) || []).length, 4);
});

test('navigation accepts arrows, j/k and Ctrl+N/P with exact modifiers', () => {
  const qml = readFileSync(require('node:path').join(__dirname, '../Tasks.qml'), 'utf8');
  const source = qml.match(/  function navigationDelta\(event\) \{[\s\S]*?\n  \}/)[0];
  const Qt = { NoModifier: 0, ControlModifier: 1, Key_N: 78, Key_P: 80,
    Key_J: 74, Key_K: 75, Key_Down: 100, Key_Up: 101 };
  const context = vm.createContext({ Qt });
  vm.runInContext(source, context);
  for (const [key, modifiers, expected] of [
    [Qt.Key_Down, 0, 1], [Qt.Key_Up, 0, -1],
    [Qt.Key_J, 0, 1], [Qt.Key_K, 0, -1],
    [Qt.Key_N, 1, 1], [Qt.Key_P, 1, -1],
    [Qt.Key_N, 0, 0], [Qt.Key_P, 0, 0], [Qt.Key_J, 1, 0],
    [Qt.Key_N, 3, 0], [Qt.Key_Down, 2, 0]
  ]) assert.equal(context.navigationDelta({ key, modifiers }), expected);
});

test('search shortcuts navigate and complete without changing focus or query', () => {
  const qml = readFileSync(require('node:path').join(__dirname, '../Tasks.qml'), 'utf8');
  const source = qml.match(/  function handleQuickTaskKey\(event\) \{[\s\S]*?\n  \}/)[0];
  const calls = [];
  const context = vm.createContext({
    Qt: { ControlModifier: 1, AltModifier: 2, Key_N: 78, Key_P: 80, Key_X: 88 },
    panelMode: 'tasks', editingLineNumber: 0,
    searchField: { activeFocus: true, text: 'invoice' },
    taskKeyCatcher: { activeFocus: false }, activeTask: { lineNumber: 7 },
    clearPrefix() {}, moveActiveTask(delta) { calls.push(delta); },
    completeTask(task) { calls.push(task.lineNumber); }
  });
  vm.runInContext(source, context);
  assert.equal(context.handleQuickTaskKey({ key: 78, modifiers: 1 }), true);
  assert.equal(context.handleQuickTaskKey({ key: 80, modifiers: 1 }), true);
  assert.equal(context.handleQuickTaskKey({ key: 88, modifiers: 2 }), true);
  assert.deepEqual(calls, [1, -1, 7]);
  assert.equal(context.searchField.activeFocus, true);
  assert.equal(context.searchField.text, 'invoice');
  assert.equal(context.handleQuickTaskKey({ key: 88, modifiers: 0 }), false);
  assert.equal(context.handleQuickTaskKey({ key: 88, modifiers: 3 }), false);
  context.editingLineNumber = 7;
  assert.equal(context.handleQuickTaskKey({ key: 88, modifiers: 2 }), false);
  context.editingLineNumber = 0;
  context.searchField.activeFocus = false;
  assert.equal(context.handleQuickTaskKey({ key: 88, modifiers: 2 }), false);
  assert.deepEqual(calls, [1, -1, 7]);
});

test('resolves default todo and done paths from the Tuxedo environment', () => {
  const home = { HOME: '/home/u' };
  assert.equal(todo.defaultTodoPath(home), '/home/u/todo.txt');
  assert.equal(todo.defaultTodoPath({ ...home, TODO_DIR: '/data/tux/' }), '/data/tux/todo.txt');
  assert.equal(todo.defaultTodoPath({ ...home, TODO_DIR: '/data', TODO_FILE: '/x/t.txt' }), '/x/t.txt');
  assert.equal(todo.defaultTodoPath({ ...home, TODO_DIR: 'rel', TODO_FILE: 'rel.txt' }), '/home/u/todo.txt');
  assert.equal(todo.donePathFor('/data/todo.txt', '', {}), '/data/done.txt');
  assert.equal(todo.donePathFor('/data/todo.txt', '', { DONE_FILE: '/arc/d.txt' }), '/arc/d.txt');
  assert.equal(todo.donePathFor('/mine/t.txt', '/mine/t.txt', { DONE_FILE: '/arc/d.txt' }), '/mine/done.txt');
});
