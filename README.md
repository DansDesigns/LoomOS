# LoomOS - WIP, DO NOT USE YET
An agenticOS combining STT, TTS & LLM.


Core Philosophy: AgentOS is designed around an LLM as the primary user interface, replacing traditional GUI-centric operating systems. The LLM interprets user intent (voice or text), orchestrates system actions, and provides responses.


During install, the hardware scan covers CPU architecture (amd64/arm64/armhf/i386), total RAM (scales Vosk model and TTS choice accordingly), GPU vendor (installs correct drivers for NVIDIA, AMD, or Intel), UEFI vs legacy BIOS (different bootloader and partition scheme), laptop vs desktop (adds TLP power management), WiFi, Bluetooth, and touchscreen. On a machine with less than 3GB RAM it automatically drops to the small Vosk model and a lighter LLM. On 8GB+ it upgrades TTS from Kokoro to Chatterbox automatically.


Starting with Bonsai 1-bit LLM as the shell, Vosk for ears, Chatterbox for voice, CRIU for process migration, NFS for mesh storage, Qtile as the graphical substrate, one shell script to install all of it.
