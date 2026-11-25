# Model-written scripts: spike results

- macOS Version 26.7.4 (Build 25G422), on-device model `SystemLanguageModel.default` (available)
- 10 runs per fixture and variation, a new session each run, default sampling, replies capped at 1500 tokens
- A run passes when the script's output on the whole input equals the expected text (trailing spaces aside)
- Scripts run in a child process killed after 2 s
- Total time: 20.2 minutes

| Fixture | Variation | First try | After one retry | Median s to first script | Slowest s | First-try failures |
|---|---|---|---|---|---|---|
| urls | baseline | 1/10 | 2/10 | 1.3 | 1.9 | 1 script error, 8 wrong output |
| urls | terse | 0/10 | 0/10 | 1.4 | 3.1 | 5 script error, 5 wrong output |
| urls | full-sample | 0/10 | 0/10 | 1.6 | 2.6 | 4 script error, 6 wrong output |
| urls | guided | 0/10 | 0/10 | 2.4 | 17.0 | 4 model error, 6 script error |
| urls | with-output | 1/10 | 1/10 | 1.4 | 17.1 | 3 script error, 6 wrong output |
| defines | baseline | 0/10 | 0/10 | 2.9 | 3.7 | 3 wrong output, 7 script error |
| defines | terse | 0/10 | 0/10 | 1.4 | 3.3 | 10 wrong output |
| defines | full-sample | 0/10 | 0/10 | 3.4 | 4.3 | 4 wrong output, 6 script error |
| defines | guided | 0/10 | 0/10 | 2.7 | 17.2 | 1 model error, 9 script error |
| defines | with-output | 0/10 | 0/10 | 3.1 | 5.1 | 2 wrong output, 8 script error |
| defines+comment | baseline | 0/10 | 0/10 | 3.3 | 5.0 | 3 wrong output, 7 script error |
| defines+comment | terse | 0/10 | 0/10 | 1.6 | 2.3 | 5 script error, 5 wrong output |
| defines+comment | full-sample | 0/10 | 0/10 | 2.7 | 17.5 | 5 script error, 5 wrong output |
| defines+comment | guided | 0/10 | 0/10 | 3.0 | 4.5 | 10 script error |
| defines+comment | with-output | 0/10 | 0/10 | 3.5 | 17.4 | 4 wrong output, 6 script error |
| string-table | baseline | 0/10 | 0/10 | 1.0 | 17.6 | 4 wrong output, 6 no script in the reply |
| string-table | terse | 0/10 | 0/10 | 2.8 | 16.8 | 4 wrong output, 6 no script in the reply |
| string-table | full-sample | 0/10 | 0/10 | 1.6 | 3.1 | 3 wrong output, 7 no script in the reply |
| string-table | guided | 0/10 | 0/10 | 1.2 | 2.1 | 1 wrong output, 4 script error, 5 no script in the reply |
| string-table | with-output | 0/10 | 0/10 | 1.2 | 2.9 | 10 no script in the reply |

## Per fixture, all variations together

| Fixture | First try | After one retry | Retries that fixed it |
|---|---|---|---|
| urls | 2/50 | 3/50 | 1/44 |
| defines | 0/50 | 0/50 | 0/49 |
| defines+comment | 0/50 | 0/50 | 0/50 |
| string-table | 0/50 | 0/50 | 0/50 |

## How failures look

Up to three different first-try failures of each kind per fixture.

### urls

- **model error** (4):
  - decodingFailure
- **script error** (19):
  - SyntaxError: Unexpected token '!'. Expected a closing '}' following an expression in template literal.
  - TypeError: Argument to String.prototype.includes cannot be a RegExp
  - TypeError: state.text.map is not a function. (In 'state.text.map(line => `https://tracker.example.test/issue/${line}`)',…
- **wrong output** (25):
  - 0 of 12 lines right; line 1 was ``, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `77`, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `https://tracker.example.test/issue/77`, expected `https://tracker.example.test/issue/4821`

### defines

- **model error** (1):
  - decodingFailure
- **script error** (30):
  - No registers found.
  - ReferenceError: Can't find variable: name
  - invalid register definition
- **wrong output** (19):
  - 0 of 10 lines right; line 1 was `ENABLE 0 Enables the block. Writing 0 holds,the block in reset.,IRQ_MASK 1,Masks the interrupt output. The status,bit is…`, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was ``, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was `Name Bit Description,ENABLE 0 Enables the block. Writing 0 holds,the block in reset.,IRQ_MASK 1,Masks the interrupt outp…`, expected `#define REG_ENABLE (0)`

### defines+comment

- **script error** (33):
  - register Bit not found
  - SyntaxError: Unexpected token '^'
  - TypeError: null is not an object (evaluating 'line.match(/^#define REG_([a-zA-Z0-9_]+)/)[1]')
- **wrong output** (17):
  - 0 of 10 lines right; line 1 was `ERROR: Invalid format for register definition,ERROR: Invalid format for register definition,ERROR: Invalid format for re…`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `Name Bit Description`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE the IRQ_MASK Masks bit MODE_SEL OVERRUN because by AVG16 16 LOOPBACK for CLK_DIV2 FIFO_FLUSH Empties …`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`

### string-table

- **no script in the reply** (34):
  - reply began: ```js⏎const lines = state.text.split("\n");⏎const error_names = lines.filter(lin
  - reply began: ```js⏎const error_names = [⏎  "ERR_NONE",⏎  "ERR_TIMEOUT",⏎  "ERR_CRC",⏎  "ERR_B
  - reply began: ```js⏎const error_names = [⏎  "ERR_NONE = 0",⏎  "ERR_TIMEOUT = 1",⏎  "ERR_CRC = 
- **script error** (4):
  - SyntaxError: Unexpected EOF
  - SyntaxError: Unexpected token '['. const declared variable 'error_names' must have an initializer.
  - SyntaxError: Unterminated regular expression literal '/'
- **wrong output** (12):
  - 0 of 12 lines right; line 1 was `ERR_NONE = 0,`, expected `static const char *const error_names[] = {`
  - 1 of 12 lines right; line 2 was `    ERR_NONE = "ERR_NONE", ERR_TIMEOUT = "ERR_TIMEOUT", ERR_CRC = "ERR_CRC", ERR_BUSY = "ERR_BUSY",`, expected `    [ERR_NONE] = "ERR_NONE",`
  - 0 of 12 lines right; line 1 was `ERR_NONE = 0`, expected `static const char *const error_names[] = {`
