# Model-written scripts: spike results

- macOS Version 26.7.4 (Build 25G422), on-device model `SystemLanguageModel.default` (available)
- 10 runs per fixture and variation, a new session each run, default sampling, replies capped at 1500 tokens
- A run passes when the script's output on the whole input equals the expected text (trailing spaces aside)
- Scripts run in a sandboxed child process killed after 2 s
- Seconds are the model's time from the request to the complete reply, without running the script
- Total time: 23.3 minutes

| Fixture | Variation | First try | After one retry | Median s to first script | Slowest s | First-try failures |
|---|---|---|---|---|---|---|
| urls | baseline | 0/10 | 0/10 | 1.5 | 2.7 | 2 script error, 8 wrong output |
| urls | terse | 0/10 | 0/10 | 1.2 | 2.0 | 3 script error, 7 wrong output |
| urls | full-sample | 0/10 | 0/10 | 1.5 | 2.3 | 2 script error, 8 wrong output |
| urls | guided | 0/10 | 0/10 | 9.6 | 16.8 | 5 model error, 5 script error |
| urls | with-output | 1/10 | 1/10 | 1.7 | 2.1 | 9 wrong output |
| defines | baseline | 0/10 | 0/10 | 2.0 | 16.7 | 5 script error, 5 wrong output |
| defines | terse | 0/10 | 0/10 | 1.4 | 2.3 | 10 wrong output |
| defines | full-sample | 0/10 | 0/10 | 3.0 | 5.1 | 5 script error, 5 wrong output |
| defines | guided | 0/10 | 0/10 | 2.3 | 17.4 | 1 model error, 9 script error |
| defines | with-output | 0/10 | 0/10 | 2.6 | 4.7 | 4 script error, 6 wrong output |
| defines+comment | baseline | 0/10 | 0/10 | 4.0 | 6.3 | 3 wrong output, 7 script error |
| defines+comment | terse | 0/10 | 0/10 | 2.5 | 16.5 | 5 script error, 5 wrong output |
| defines+comment | full-sample | 0/10 | 0/10 | 3.4 | 5.8 | 10 script error |
| defines+comment | guided | 0/10 | 0/10 | 3.4 | 5.7 | 10 script error |
| defines+comment | with-output | 0/10 | 0/10 | 3.6 | 4.7 | 4 wrong output, 6 script error |
| string-table | baseline | 0/10 | 0/10 | 17.0 | 17.3 | 10 no script in the reply |
| string-table | terse | 0/10 | 0/10 | 9.8 | 17.2 | 2 wrong output, 8 no script in the reply |
| string-table | full-sample | 0/10 | 0/10 | 1.6 | 2.1 | 1 wrong output, 9 no script in the reply |
| string-table | guided | 0/10 | 0/10 | 1.0 | 3.0 | 5 no script in the reply, 5 script error |
| string-table | with-output | 0/10 | 0/10 | 1.2 | 1.9 | 10 no script in the reply |

## Per fixture, all variations together

| Fixture | First try | After one retry | Retries that fixed it |
|---|---|---|---|
| urls | 1/50 | 1/50 | 0/44 |
| defines | 0/50 | 0/50 | 0/49 |
| defines+comment | 0/50 | 0/50 | 0/50 |
| string-table | 0/50 | 0/50 | 0/50 |

## How failures look

Up to three different first-try failures of each kind per fixture.

### urls

- **model error** (5):
  - decodingFailure
- **script error** (12):
  - TypeError: state.text.join is not a function. (In 'state.text.join("\n")', 'state.text.join' is undefined)
  - TypeError: state.text.map is not a function. (In 'state.text.map(line => `https://tracker.example.test/issue/${line}`)',…
  - TypeError: Argument to String.prototype.includes cannot be a RegExp
- **wrong output** (32):
  - 0 of 12 lines right; line 1 was ``, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `ticket 4821,#1093 (reopened),77,see 20455, urgent,  318  ,id=9002;,no. 64 - duplicate,PR 15007 merged,5120?,bug: 733 aga…`, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `https://tracker.example.test/issue/77,https://tracker.example.test/issue/5120,https://tracker.example.test/issue/41`, expected `https://tracker.example.test/issue/4821`

### defines

- **model error** (1):
  - decodingFailure
- **script error** (23):
  - SyntaxError: Unexpected end of script
  - Invalid register table format
  - no registers found
- **wrong output** (26):
  - 0 of 10 lines right; line 1 was `Name Bit Description`, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was `ENABLE 0 Enables the block. Writing 0 holds,the block in reset.,IRQ_MASK 1,Masks the interrupt output. The status,bit is…`, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE (undefined)`, expected `#define REG_ENABLE (0)`

### defines+comment

- **script error** (38):
  - TypeError: line.split is not a function. (In 'line.split(" ")', 'line.split' is undefined)
  - Invalid header or register format.
  - TypeError: undefined is not an object (evaluating 'parts[2].trim')
- **wrong output** (12):
  - 0 of 10 lines right; line 1 was `Name Bit Description`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */#define REG_IRQ_MASK (1) /* Masks the…`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `ODE_SEL 2 Selects the sampling mode.`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`

### string-table

- **no script in the reply** (42):
  - reply began: ```js⏎const error_names = [⏎  "ERR_NONE = 0",⏎  "ERR_TIMEOUT = 1",⏎  "ERR_CRC = 
  - reply began: ```javascript⏎const error_names = [⏎  "ERR_NONE",⏎  "ERR_TIMEOUT",⏎  "ERR_CRC",⏎
  - reply began: ```js⏎const lines = state.text.split("\n");⏎state.text = lines.filter(line => !l
- **script error** (5):
  - SyntaxError: Unexpected EOF
  - SyntaxError: Unterminated regular expression literal '/'
- **wrong output** (3):
  - 1 of 12 lines right; line 2 was `    for each code, a line of four spaces followed by [ERR_X] = "ERR_X", and last the line;`, expected `    [ERR_NONE] = "ERR_NONE",`
  - 0 of 12 lines right; line 1 was `ERR_NONE = 0`, expected `static const char *const error_names[] = {`
  - 0 of 12 lines right; line 1 was `ERR_NONE = 0,`, expected `static const char *const error_names[] = {`
