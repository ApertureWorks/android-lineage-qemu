# [DEPRECATED] Aperture Android Image Build & Packaging Tooling

> [!WARNING]
> **DEPRECATION NOTICE:**  
> This directory and its associated image generation workflows are **deprecated and scrapped**. Building complete Android images from source requires massive continuous integration infrastructure and computational resources that are not sustained in local development.  
> 
> The project instead relies on pre-built LineageOS/AOSP ARM64 release images dynamically patched at runtime via `ApertureImagePatcher.swift` and injected via `e2tools` / `debugfs`.

---

## Historical Context

This repository was originally forked from [`jqssun/android-lineage-qemu`](https://github.com/jqssun/android-lineage-qemu.git) to explore automated LineageOS 21 builds with baked-in VirtIO drivers and pre-patched `vulkan.virtio.so` binaries. 

For current image preparation and guest-agent injection, refer to `Desktop/Aperture/Downloads/` and `Desktop/Aperture/ImagePatcher/`.
