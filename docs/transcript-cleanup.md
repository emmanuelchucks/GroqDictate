# Transcript cleanup: phantom phrases and spelling fixes

Whisper writes stock phrases ("Thank you.", "Thank you for watching.", "Subtitles by the Amara.org community") over stretches with no speech, sometimes drops the user's words (a word or two over seconds of speech, or no segment at all), and mishears names. Both apps clean the text Groq returns. They never change the audio or the request.

## What was measured (12 Nov 2026, whisper-large-v3 on Groq, 89 iPhone parts and 9 Mac clips from real dictation)

- 104 segments were nothing but phantom phrases. An independent speech detector (Silero VAD) found no speech under 94 of them. They sit mid-recording, where the user paused to read, more often than at either end, so position in the recording doesn't pick them out.
- Under 6 of the other 10, real speech had been replaced by the phrase: transcribed alone, the same stretch gave the user's words. Removing the phrase there loses nothing more, but keeping it marks where words went missing.
- Groq's `no_speech_prob` ranged from 0.001 to 0.96 on phantoms with no speech under them, and loudness under them ranged from 20 dB below to 36 dB above the user's speech level (family, TV). Neither separates them.
- Groq's text is exactly the segments' texts joined, so keeping segments keeps the text unchanged.
- The same request twice gave different text for 24 of 89 parts, so before/after comparisons apply the cleanup to one response.
- On parts after the first, the previous part's tail as prompt gave 58 phantom "thank you"s against 107 without it. The request keeps it.

## What was measured (17 Nov 2026, the iPhone's recordings)

- Saved audio matches recorded time on every recording since 11 Nov (362 takes, none short by more than 3 s), and the M4A each part is uploaded as is as long as the part (404 parts). Words go missing in Groq's answer, not before it.
- Groq dropped the end of the user's dictation: on a 66 s recording it wrote "you." over the last 15 s of speech, the same on two requests, and sent alone that stretch gave his three sentences back. Other endings came back as a repeat loop ("it it it it") or garbled ("for an I A I").
- Over the 89 parts above, a segment or gap with fewer than 1.5 words per second of voice under it (two seconds of voice or more) occurred 41 times beyond the phantom candidates when voice half a second beside it counted, and 20 times counting only voice inside it, at most five a part. Of the 41 sent alone, 17 answers had more words: the user's own lost words 12 times (from a few words to a paragraph, including 30 s Groq had written as "I'm not sure what I meant by that phrasing"), other people in the room 4 times ("I see. I see.", "Hmm.", "Good."), and a different hearing once. The 20 keep the paragraph-sized recoveries and drop most of the room noise and a few small ones (two or three words). His dictation runs at 1.6 words per second of voice or more; at 1.0 instead of 1.5, one of the lost endings (12 words over 11.4 s) is missed.
- A repeat loop ("it it it it" for a sentence) is caught only when it is short for the voice under it; one with many words is not.
- Identical audio gets the identical answer from Groq, but any change to the bytes (a re-encode, a different start) can bring back words it dropped, or drop others; sending a stretch alone is such a second try. One 26 Oct ending was lost again when its stretch was sent alone.

## Rule

A segment is removed only when both hold:

1. Its whole text, lowercased with punctuation and spaces collapsed, is one or more phrases from `PhantomPhrases.list` (or nothing but punctuation). Single common words ("you", "okay") stay off the list.
2. Silero VAD (v6.2.1 as Core ML, 256 ms windows, `Shared/SpeechCheck.swift`) hears no voice within the segment or half a second either side (Whisper's timings are loose): its probability stays under 0.5 in every window there. It starts ten seconds before the stretch, on the same 256 ms grid as a pass over the whole file, because it carries state from window to window. If it can't read the audio or load the model, nothing is removed.

A segment that repeats the prompt (20 characters or more found in it) is a candidate too: Whisper echoes the prompt on silence. Before, the iPhone emptied such a part on text alone.

Everything else stays. A candidate with a voice under it (with the half-second margin), and any segment or gap with two seconds of voice or more inside it and fewer than 1.5 words per second of that voice (gaps of two seconds or more, including before the first segment and after the last, using Groq's `duration`), is sent to Groq once more on its own, at most five stretches a part, those over the most voice first (the segment's time, half a second either side but not into neighbours with words, as a temporary M4A clip, no prompt): Whisper sometimes replaces real words with the phrase. Voiced candidates next to each other go as one stretch: sent separately their stretches overlapped and the same words came back twice. The answer's first and last words that repeat the kept text just before or after it (up to five each side) are dropped first ("…next also" plus "also" leaves nothing new). Listed phrases standing as sentences of their own at the answer's start or end are dropped too ("…we ship it. Thank you."; "Thank you for the fix." stays). If the answer then has more of the user's words than the stretch had (phantom phrases and prompt echoes count as none) it replaces the stretch's text; if it is phantom phrases again (a real "thank you"), no longer, fails, or is rate-limited, the text stays. On the user's recordings, 34 such stretches gave back: the user's lost words 7 times (whole sentences), short words 12 times ("Yes.", "Amen.", some likely from the room), and the phrase again 15 times. Phantoms over TV or other people's voices can therefore become what those voices said.

## Owners

| Job | Owner | Not |
| --- | --- | --- |
| Words and timings | Groq `verbose_json` segments | our own audio cutting or VAD trimming |
| Is anyone speaking here | Silero VAD as Core ML on the CPU only, both platforms (`Shared/Models/silero-vad.mlmodelc`) | Apple's built-in sound classifier (it runs on the GPU, which iOS refuses to apps in the background), loudness thresholds, Groq scores |
| Which phrases are phantoms | `PhantomPhrases` list in `Shared/`, matched whole | substring or prefix matching |
| Names | the user's "Spelling fixes" setting, applied after cleanup, whole words | Whisper's prompt |
| Recovering a wrong removal | the unfiltered text kept beside the cleaned text | logs (transcript text is never logged) |
| Words Whisper replaced with a phrase, or dropped | a second Groq request for that stretch alone | our own speech recognition, splitting every part into short requests (Groq's 20 requests a minute) |

## Where it runs

- Shared code in `Shared/` is compiled into both apps: the phrase list and matching, the segment filter (pure, tested), spelling fixes (pure, tested) and the speech check.
- iPhone: the transcription pass cleans each part after Groq answers, reading the part's own audio, and stores `rawTranscript` (Groq's text) and `transcript` (cleaned) in one `SessionStore.update`. The next part's prompt uses the cleaned text. Spelling fixes apply when a transcript is shown or copied, so editing the list fixes old recordings too. The recording's detail shows "Copy original" when the two differ.
- Mac: `DictationWorkflowCoordinator` cleans the transcript on the WAV before deleting it, then pastes the cleaned, fixed text; a dictation that was only phantoms shows "No speech". The menu's "Copy Original Transcript" is enabled after a removal.
- The voice check runs only when some segment is a candidate or has fewer than 1.5 words per second of its length, and only over those stretches. It answers seconds of voice per stretch; if it can't read the file, nothing is removed or sent again.

## Spelling fixes

One line per name: `Right: wrong, wrong`, for example `XcodeGen: x code gen, Xcode Jen`. All wrong forms go into one pattern, longest first, applied once, so one fix's output is never fixed again. Each matches as a whole word or phrase (no letter or digit on either side, any whitespace between words), ignoring case, and is replaced by the right form as typed. A real word listed as a wrong form ("grok") is replaced everywhere. Lines are kept on the device (the repo is public, so names aren't in code). It replaces the iPhone's vocabulary-hints prompt field, which is no longer sent.

Apple's built-in sound classifier can't do this job on the iPhone. It failed every check made in the background (10 of 10, 12 to 14 Nov; all 21 in front worked): it runs on the GPU, and iOS refuses GPU work from the background (`kIOGPUCommandBufferCallbackErrorBackgroundExecutionNotPermitted`). It has no CPU option, and Speech's `SpeechDetector` needs iOS 26, which the iPhone XR can't run.

Measured with Silero (Core ML, CPU only, the shipped Swift code on the Mac, 14 Nov) on the same recordings: 19,814 s of audio in 21.7 s. The user's speech scores about 1.0, including the Bluetooth clips from the Mac that Apple's classifier scored as low as 0.33, so one threshold serves every mic. Checking stretches as the app does, it removes 94 of 140 candidates (Apple's classifier removed 86), none with speech under it by Python Silero, and keeps all four real "Thank you" clips. With one to three seconds before a stretch instead of ten, stretch-only checks disagreed with a whole-file pass on 12 to 14 of 140 stretches, once removing where the whole file heard 0.57; with ten, the 10 that differ all keep text. The XR logs each check as `speechChecked` (code: stretches checked with no voice in them, gaps included, -1 when the audio couldn't be read).

## How it's checked

`phantom-filter/` in the project home (outside the repo) holds copies of the recordings, Groq's responses, and a harness that runs the shipped Swift cleanup on the Mac over every response. Pass: every difference between Groq's text and the cleaned text is a listed phrase removed or a spelling fixed, every removed segment has no speech under it by both detectors, and a real spoken "thank you" survives.
