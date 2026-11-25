import Foundation

/// One task: what the user asks for, the text, and what a correct script
/// turns the text into. All of it is made up for the spike: no real
/// datasheet, tracker or code base.
public struct Fixture: Sendable {
    public var id: String
    public var instruction: String
    public var input: String
    public var expected: String
    /// How many leading lines of `input` the model sees as the short sample.
    public var sampleLines: Int
    /// What a correct script makes of the short sample alone: the worked
    /// example of the "with-output" variation.
    public var sampleExpected: String
    /// A hand-written script that passes, which proves the fixture and the
    /// runner agree before the model is asked anything.
    public var reference: String

    public var shortSample: String {
        input.split(separator: "\n", omittingEmptySubsequences: false).prefix(sampleLines).joined(separator: "\n")
    }

    public static let all = [urls, definesPlain, definesCommented, stringTable]

    /// 1. Numbers with stray text to URLs with a fixed prefix. The short
    /// sample does not show the two lines without a number.
    public static let urls = Fixture(
        id: "urls",
        instruction: "Every line holds one number with stray text around it. Replace each line with https://tracker.example.test/issue/<number>. Drop lines that have no number.",
        input: """
        ticket 4821
        #1093 (reopened)
        77
        see 20455, urgent
          318\u{20}\u{20}
        id=9002;
        no. 64 - duplicate

        (none yet)
        PR 15007 merged
        5120?
        bug: 733 again
        Ref.88
        41 and counting
        """,
        expected: [4821, 1093, 77, 20455, 318, 9002, 64, 15007, 5120, 733, 88, 41]
            .map { "https://tracker.example.test/issue/\($0)" }.joined(separator: "\n"),
        sampleLines: 5,
        sampleExpected: [4821, 1093, 77, 20455, 318].map { "https://tracker.example.test/issue/\($0)" }.joined(separator: "\n"),
        reference: """
        function main(state) {
          state.text = state.text.split("\\n")
            .map(line => line.match(/\\d+/))
            .filter(found => found)
            .map(found => "https://tracker.example.test/issue/" + found[0])
            .join("\\n");
        }
        """
    )

    static let registerTable = """
    Name Bit Description
    ENABLE 0 Enables the block. Writing 0 holds
    the block in reset.
    IRQ_MASK 1
    Masks the interrupt output. The status
    bit is still set.
    MODE_SEL 2 Selects the sampling mode.
    OVERRUN 5 Set when a sample was lost
    because the buffer was full. Cleared
    by writing 1.
    AVG16 7
    16 samples are averaged when set.
    LOOPBACK 9 Connects the output to the input
    for self test.
    CLK_DIV2 12 Halves the clock.
    FIFO_FLUSH 13
    Empties the buffer. Reads as 0.
    WAKE_EN 20 Lets a pin change wake
    the block
    from sleep.
    LOCK 31 Write once. Blocks further writes
    until reset.
    """

    static let registers: [(name: String, bit: Int, description: String)] = [
        ("ENABLE", 0, "Enables the block. Writing 0 holds the block in reset."),
        ("IRQ_MASK", 1, "Masks the interrupt output. The status bit is still set."),
        ("MODE_SEL", 2, "Selects the sampling mode."),
        ("OVERRUN", 5, "Set when a sample was lost because the buffer was full. Cleared by writing 1."),
        ("AVG16", 7, "16 samples are averaged when set."),
        ("LOOPBACK", 9, "Connects the output to the input for self test."),
        ("CLK_DIV2", 12, "Halves the clock."),
        ("FIFO_FLUSH", 13, "Empties the buffer. Reads as 0."),
        ("WAKE_EN", 20, "Lets a pin change wake the block from sleep."),
        ("LOCK", 31, "Write once. Blocks further writes until reset."),
    ]

    static let registerPreamble = "This is a register table pasted from a PDF. After the header line, each register starts on a line with its NAME and its bit number. Its description follows on the same line or on the next line, and may wrap over several lines."

    static let registerReference = """
    function main(state) {
      const rows = [];
      for (const line of state.text.split("\\n").slice(1)) {
        const start = line.match(/^([A-Z][A-Z0-9_]*)\\s+(\\d+)\\b\\s*(.*)$/);
        if (start) rows.push({ name: start[1], bit: start[2], words: start[3] ? [start[3].trim()] : [] });
        else if (rows.length && line.trim()) rows[rows.length - 1].words.push(line.trim());
      }
      state.text = rows.map(row => COMMENT
        ? "#define REG_" + row.name + " (" + row.bit + ") /* " + row.words.join(" ") + " */"
        : "#define REG_" + row.name + " (" + row.bit + ")").join("\\n");
    }
    """

    /// 2a. The register table to `#define` lines, descriptions left out.
    public static let definesPlain = Fixture(
        id: "defines",
        instruction: "\(registerPreamble) Write one line per register: #define REG_<NAME> (<bit>). Leave out the header line and the descriptions.",
        input: registerTable,
        expected: registers.map { "#define REG_\($0.name) (\($0.bit))" }.joined(separator: "\n"),
        sampleLines: 7,
        sampleExpected: registers.prefix(3).map { "#define REG_\($0.name) (\($0.bit))" }.joined(separator: "\n"),
        reference: registerReference.replacingOccurrences(of: "COMMENT", with: "false")
    )

    /// 2b. The same, with each description as a comment on its line.
    public static let definesCommented = Fixture(
        id: "defines+comment",
        instruction: "\(registerPreamble) Write one line per register: #define REG_<NAME> (<bit>) /* <description> */ with the whole description joined into that one line by single spaces. Leave out the header line.",
        input: registerTable,
        expected: registers.map { "#define REG_\($0.name) (\($0.bit)) /* \($0.description) */" }.joined(separator: "\n"),
        sampleLines: 7,
        sampleExpected: registers.prefix(3).map { "#define REG_\($0.name) (\($0.bit)) /* \($0.description) */" }.joined(separator: "\n"),
        reference: registerReference.replacingOccurrences(of: "COMMENT", with: "true")
    )

    static let errorCodes = ["ERR_NONE", "ERR_TIMEOUT", "ERR_CRC", "ERR_BUSY", "ERR_NO_DEVICE", "ERR_BAD_PARAM",
                             "ERR_OVERFLOW", "ERR_UNDERFLOW", "ERR_NOT_READY", "ERR_UNSUPPORTED"]

    /// 3. Error codes to a C string table. The short sample shows one
    /// trailing comment; the blank line, the comment-only line and the last
    /// line without a comma come later.
    public static let stringTable = Fixture(
        id: "string-table",
        instruction: "This is a list of C error codes. Write a C string table: first the line static const char *const error_names[] = { then, for each code, a line of four spaces followed by [ERR_X] = \"ERR_X\", and last the line }; Ignore the values, the comments and blank lines.",
        input: """
        ERR_NONE = 0,
        ERR_TIMEOUT = 1,
        ERR_CRC = 2,   // checksum mismatch
        ERR_BUSY = 3,

        ERR_NO_DEVICE = 4,
        ERR_BAD_PARAM = 5, /* the caller's fault */
        ERR_OVERFLOW = 6,
        ERR_UNDERFLOW = 7,
        // reserved: 8
        ERR_NOT_READY = 9,
        ERR_UNSUPPORTED = 10
        """,
        expected: (["static const char *const error_names[] = {"]
            + errorCodes.map { "    [\($0)] = \"\($0)\"," } + ["};"]).joined(separator: "\n"),
        sampleLines: 4,
        sampleExpected: (["static const char *const error_names[] = {"]
            + errorCodes.prefix(4).map { "    [\($0)] = \"\($0)\"," } + ["};"]).joined(separator: "\n"),
        reference: """
        function main(state) {
          const names = state.text.split("\\n")
            .map(line => line.match(/^\\s*([A-Z][A-Z0-9_]*)\\s*=/))
            .filter(found => found)
            .map(found => "    [" + found[1] + "] = \\"" + found[1] + "\\",");
          state.text = ["static const char *const error_names[] = {"].concat(names, ["};"]).join("\\n");
        }
        """
    )
}
