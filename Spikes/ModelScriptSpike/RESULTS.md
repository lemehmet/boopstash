# Model-written scripts: spike results

- macOS Version 26.7.4 (Build 25G422), on-device model `SystemLanguageModel.default` (available)
- 10 runs per fixture and variation, a new session each run, default sampling, replies capped at 1500 tokens
- A run passes when the script's output on the whole input equals the expected text (trailing spaces aside)
- Scripts run in a sandboxed child process killed after 2 s
- Seconds are the model's time from the request to the complete reply, without running the script
- Total time: 19.3 minutes

| Fixture | Variation | First try | After one retry | Median s to first reply | Slowest s | First-try failures |
|---|---|---|---|---|---|---|
| urls | baseline | 0/10 | 0/10 | 1.8 | 2.1 | 2 script error, 8 wrong output |
| urls | terse | 0/10 | 0/10 | 1.0 | 2.7 | 2 script error, 8 wrong output |
| urls | full-sample | 1/10 | 1/10 | 1.3 | 2.3 | 2 script error, 7 wrong output |
| urls | guided | 0/10 | 0/10 | 16.9 | 17.0 | 2 script error, 8 model error |
| urls | with-output | 0/10 | 0/10 | 1.9 | 2.6 | 1 script error, 9 wrong output |
| defines | baseline | 0/10 | 0/10 | 1.9 | 4.6 | 5 script error, 5 wrong output |
| defines | terse | 0/10 | 0/10 | 1.0 | 4.4 | 1 script error, 1 timed out, 8 wrong output |
| defines | full-sample | 0/10 | 0/10 | 2.5 | 5.1 | 3 script error, 7 wrong output |
| defines | guided | 0/10 | 0/10 | 2.5 | 4.5 | 10 script error |
| defines | with-output | 0/10 | 0/10 | 3.0 | 4.8 | 2 wrong output, 8 script error |
| defines+comment | baseline | 0/10 | 0/10 | 3.4 | 4.9 | 4 wrong output, 6 script error |
| defines+comment | terse | 0/10 | 0/10 | 1.9 | 3.0 | 1 script error, 9 wrong output |
| defines+comment | full-sample | 0/10 | 0/10 | 3.0 | 4.6 | 5 script error, 5 wrong output |
| defines+comment | guided | 0/10 | 0/10 | 3.1 | 4.8 | 10 script error |
| defines+comment | with-output | 0/10 | 0/10 | 4.0 | 4.6 | 2 wrong output, 8 script error |
| string-table | baseline | 0/10 | 0/10 | 9.2 | 16.9 | 10 no script in the reply |
| string-table | terse | 0/10 | 0/10 | 1.5 | 17.0 | 3 wrong output, 7 no script in the reply |
| string-table | full-sample | 0/10 | 0/10 | 1.7 | 3.1 | 1 wrong output, 9 no script in the reply |
| string-table | guided | 0/10 | 0/10 | 1.2 | 1.5 | 2 wrong output, 3 no script in the reply, 5 script error |
| string-table | with-output | 0/10 | 0/10 | 1.2 | 1.2 | 10 no script in the reply |

## Per fixture, all variations together

| Fixture | First try | After one retry | Retries that fixed it | Retries with the same script again |
|---|---|---|---|---|
| urls | 1/50 | 1/50 | 0/41 | 30/41 |
| defines | 0/50 | 0/50 | 0/50 | 39/50 |
| defines+comment | 0/50 | 0/50 | 0/50 | 42/50 |
| string-table | 0/50 | 0/50 | 0/50 | 15/50 |

## Totals

- First tries: 1 of 200 pass. Failures: 1 timed out, 39 no script in the reply, 71 script error, 8 model error, 80 wrong output.
- Retries: 191 (a model error is not retried). Fixed: 0. The same script again: 126.
- Seconds are to the complete first reply, whether or not it held a script.

## How failures look

Up to three different first-try failures of each kind per fixture.

### urls

- **model error** (8):
  - decodingFailure
- **script error** (9):
  - Invalid line format; Invalid line format; Invalid line format; Invalid line format; Invalid line format; Invalid line fo…
  - TypeError: undefined is not an object (evaluating 'match[1].trim')
  - TypeError: state.text.filter is not a function. (In 'state.text.filter(line => line.match(/\d+/))', 'state.text.filter' …
- **wrong output** (32):
  - 0 of 12 lines right; line 1 was `https://tracker.example.test/issue/reopened`, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `https://tracker.example.test/issue/4821,https://tracker.example.test/issue/1093,https://tracker.example.test/issue/20455…`, expected `https://tracker.example.test/issue/4821`
  - 0 of 12 lines right; line 1 was `https://tracker.example.test/issue/7,https://tracker.example.test/issue/5120,https://tracker.example.test/issue/41`, expected `https://tracker.example.test/issue/4821`

### defines

- **script error** (27):
  - invalid register line
  - Register ENABLE (0); Invalid bit number for register the
  - TypeError: registerBitNumbers.get is not a function. (In 'registerBitNumbers.get(register)', 'registerBitNumbers.get' is…
- **timed out** (1):
  - killed after 2 s
- **wrong output** (22):
  - 0 of 10 lines right; line 1 was `#define REG_Name (Bit)`, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE (0),#define REG_the (block),#define REG_IRQ_MASK (1),#define REG_Masks (the),#define REG_bit (is),#de…`, expected `#define REG_ENABLE (0)`
  - 0 of 10 lines right; line 1 was `Name Bit Description`, expected `#define REG_ENABLE (0)`

### defines+comment

- **script error** (30):
  - SyntaxError: Invalid regular expression: invalid flags
  - TypeError: Attempted to assign to readonly property.
  - SyntaxError: Cannot declare a const variable twice: 'lines'.
- **wrong output** (20):
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds */,#define REG_the (block) /* in reset. */,#define REG_IRQ_…`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `N#d#d#d#d#d#d#d#d#d#d#define REG_untilreset. /*    */ine REG_fromsleep. /* LOCK 31 Write once. Blocks further writes */i…`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`
  - 0 of 10 lines right; line 1 was `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds */`, expected `#define REG_ENABLE (0) /* Enables the block. Writing 0 holds the block in reset. */`

### string-table

- **no script in the reply** (39):
  - reply began: ```js⏎const error_names = [];⏎const error_codes = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
  - reply began: ```js⏎const error_names = [⏎  "ERR_NONE",⏎  "ERR_TIMEOUT",⏎  "ERR_CRC",⏎  "ERR_B
  - reply began: ```js⏎const lines = document.querySelectorAll("pre code");⏎const error_names = [
- **script error** (5):
  - SyntaxError: Unexpected EOF
  - SyntaxError: Unterminated regular expression literal '/'
  - SyntaxError: Unexpected token '['. const declared variable 'error_names' must have an initializer.
- **wrong output** (6):
  - 1 of 12 lines right; line 2 was `    ERR_NONE = 0,`, expected `    [ERR_NONE] = "ERR_NONE",`
  - 0 of 12 lines right; line 1 was `ERR_NONE`, expected `static const char *const error_names[] = {`
  - 0 of 12 lines right; line 1 was ``, expected `static const char *const error_names[] = {`
