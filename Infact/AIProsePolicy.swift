// Adapted from GaZmagik/iso-24495, iso-24495-1 v0.7.0:
// https://github.com/GaZmagik/iso-24495/blob/main/skills/iso-24495-1/SKILL.md
// This is plain-language guidance, not a claim of ISO conformance.
//
// MIT License
// Copyright (c) 2026 Gareth Williams
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

enum AIProsePolicy {
    static let version = "plain-language-v1"

    /// Apply at generation time, before prose reaches the store or the UI.
    static func instructions(for task: String) -> String {
        task + "\n\n" + guidance
    }

    /// Compact rules keep the on-device model's context available for evidence.
    static let guidance = """
    Plain-language rules for prose you write:
    Write for a reader learning from their saved sources. Include what helps them understand the
    subject. Lead with the main point, not a filler introduction. Prefer familiar words and active
    voice. Keep one main idea per sentence; aim for 15 to 20 words and at most 30 words per sentence.
    Use short paragraphs with at most five sentences. Remove filler and use one term for each concept.
    Make causes, conditions, and contrasts explicit. Preserve uncertainty, limitations, and scope;
    factual accuracy takes priority over simpler wording. Explain unfamiliar acronyms when evidence
    supplies their meaning. Never invent definitions or facts to make prose easier to read.
    For mind maps, put the main idea in each title and explain its contribution in one short sentence.
    Group related ideas under meaningful branches. Titles and summaries are plain text, not Markdown.
    For longer prose, use descriptive headings and lists when the output format permits them.
    These rules apply only to prose you compose. Preserve source names, verbatim quotations, citations,
    code, commands, URLs, identifiers, schema keys, and enum values exactly as the task requires.
    Follow the task's output schema and tighter length limits. Before returning, check that the prose
    is relevant, easy to find, understandable, and useful without changing the source's meaning.
    """
}
