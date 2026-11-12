# Transcript cleanup: phantom phrases and spelling fixes

Whisper writes stock phrases ("Thank you.", "Thank you for watching.", "Subtitles by the Amara.org community") over stretches with no speech, and mishears names. Both apps clean the text Groq returns. They never change the audio or the request.

## What was measured (12 Nov 2026, whisper-large-v3 on Groq, 89 iPhone parts and 9 Mac clips from real dictation)

- 104 segments were nothing but phantom phrases. An independent speech detector (Silero VAD) found no speech under 94 of them. They sit mid-recording, where the user paused to read, more often than at either end, so position in the recording doesn't pick them out.
- Under 6 of the other 10, real speech had been replaced by the phrase: transcribed alone, the same stretch gave the user's words. Removing the phrase there loses nothing more, but keeping it marks where words went missing.
- Groq's `no_speech_prob` ranged from 0.001 to 0.96 on phantoms with no speech under them, and loudness under them ranged from 20 dB below to 36 dB above the user's speech level (family, TV). Neither separates them.
- Groq's text is exactly the segments' texts joined, so keeping segments keeps the text unchanged.
- The same request twice gave different text for 24 of 89 parts, so before/after comparisons apply the cleanup to one response.
- On parts after the first, the previous part's tail as prompt gave 58 phantom "thank you"s against 107 without it. The request keeps it.

## Rule

A segment is removed only when both hold:

1. Its whole text, lowercased with punctuation and spaces collapsed, is one or more phrases from `PhantomPhrases.list` (or nothing but punctuation). Single common words ("you", "okay") stay off the list.
2. Apple's built-in sound classifier (`SoundAnalysis`, `SNClassifySoundRequest(.version1)`, 1 s windows overlapping by half) hears no voice within the segment or half a second either side (Whisper's timings are loose): the highest of its voice labels (speech, whispering, shouting, singing, chatter and the like, `SpeechCheck.voiceLabels`) stays under the threshold. Real speech through the iPhone's own mic scored 0.74 or more, so audio from any mic that isn't Bluetooth uses 0.5 (`widebandMicThreshold`). Short words through the Bluetooth earpiece scored as low as 0.33, so Bluetooth audio uses 0.25: the Mac reads the selected mic's transport type when a dictation stops (unknown counts as Bluetooth), and the iPhone notes whether a Bluetooth input was used at any point in a part (older parts count as Bluetooth). None of 89 iPhone parts from 29 Aug to 12 Nov was recorded through the earpiece (earpiece audio has nothing above 4 kHz). If the classifier can't read the audio, nothing is removed.

A segment that repeats the prompt (20 characters or more found in it) is a candidate too: Whisper echoes the prompt on silence. Before, the iPhone emptied such a part on text alone.

Everything else stays. A candidate with a voice under it is sent to Groq once more on its own (the segment's time, half a second either side but not into its neighbours, as a temporary M4A clip, no prompt): Whisper sometimes replaces real words with the phrase. If the answer is more than phantom phrases it replaces the phrase; if it is phantom phrases again (a real "thank you"), fails, or is rate-limited, the phrase stays. On the user's recordings, 34 such stretches gave back: the user's lost words 7 times (whole sentences), short words 12 times ("Yes.", "Amen.", some likely from the room), and the phrase again 15 times. Phantoms over TV or other people's voices can therefore become what those voices said.

## Owners

| Job | Owner | Not |
| --- | --- | --- |
| Words and timings | Groq `verbose_json` segments | our own audio cutting or VAD trimming |
| Is anyone speaking here | `SoundAnalysis` built-in classifier, both platforms | loudness thresholds, Groq scores, a bundled model |
| Which phrases are phantoms | `PhantomPhrases` list in `Shared/`, matched whole | substring or prefix matching |
| Names | the user's "Spelling fixes" setting, applied after cleanup, whole words | Whisper's prompt |
| Recovering a wrong removal | the unfiltered text kept beside the cleaned text | logs (transcript text is never logged) |
| Words Whisper replaced with a phrase | a second Groq request for that stretch alone | our own speech recognition |

## Where it runs

- Shared code in `Shared/` is compiled into both apps: the phrase list and matching, the segment filter (pure, tested), spelling fixes (pure, tested) and the speech check.
- iPhone: the transcription pass cleans each part after Groq answers, reading the part's own audio, and stores `rawTranscript` (Groq's text) and `transcript` (cleaned) in one `SessionStore.update`. The next part's prompt uses the cleaned text. Spelling fixes apply when a transcript is shown or copied, so editing the list fixes old recordings too. The recording's detail shows "Copy original" when the two differ.
- Mac: `DictationWorkflowCoordinator` cleans the transcript on the WAV before deleting it, then pastes the cleaned, fixed text; a dictation that was only phantoms shows "No speech". The menu's "Copy Original Transcript" is enabled after a removal.
- The classifier runs only when some segment is a candidate, and only over those stretches. If it can't read the file, nothing is removed.

## Spelling fixes

One line per name: `Right: wrong, wrong`, for example `XcodeGen: x code gen, Xcode Jen`. All wrong forms go into one pattern, longest first, applied once, so one fix's output is never fixed again. Each matches as a whole word or phrase (no letter or digit on either side, any whitespace between words), ignoring case, and is replaced by the right form as typed. A real word listed as a wrong form ("grok") is replaced everywhere. Lines are kept on the device (the repo is public, so names aren't in code). It replaces the iPhone's vocabulary-hints prompt field, which is no longer sent.

Measured with Apple's classifier on the same recordings (12 Nov, macOS): it never called a stretch quiet where Silero heard speech. Only the candidate stretches are classified, with a second more audio either side so the windows at the margin hear what they would in the whole file; whole-file classification of a five-minute part took 8.7 s on the iPhone XR, the stretches 2.0 s. On 89 iPhone parts it removes 82 of 128 candidates (Silero alone would allow 113), every removal has no Silero speech within the margin, and all four test clips with the user's real "Thank you" put into a silent stretch keep it, on the Mac and on the XR. The XR logs each check as `speechChecked` (code: segments removed, -1 when the audio couldn't be read).

## How it's checked

`phantom-filter/` in the project home (outside the repo) holds copies of the recordings, Groq's responses, and a harness that runs the shipped Swift cleanup on the Mac over every response. Pass: every difference between Groq's text and the cleaned text is a listed phrase removed or a spelling fixed, every removed segment has no speech under it by both detectors, and a real spoken "thank you" survives.
