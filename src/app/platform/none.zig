//! The `none` platform: no built-in host. The app's own code drives the
//! runtime: it feeds input in, runs frames, and takes render commands and
//! changed regions out, for a portable renderer to draw into pixels. Every
//! widget is drawn by fabrum.
//!
//! This is for hosts fabrum can't know about: a VNC server that shows a
//! fabrum interface over (or instead of) a video stream, an overlay drawn
//! into a game's frames, a test rig, or a program that only wants layout.
//! It links no OS UI library, so it builds for any target.
