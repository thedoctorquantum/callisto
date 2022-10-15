# Callisto 

An embeddable virtual machine/compiler toolchain primarily targeted for plugin systems.

## Planned Features: 

- A well defined, low level, untyped register machine that works for modern machines
- A simple module format inspired by elf and wasm 
- A set of assembly and dissasembly tools for reverse engineering/debugging and developing this project
- A reusable code generation library for creating and extending compilers to target the callisto abstract machine 
- A virtual machine implementation that can be used as a standalone executable or be embedded into other applications via the zig/c apis

## Building

### Requirements: 
- Git
- Zig

**1. Clone the repository**

* `git clone --recursive https://github.com/thedoctorquantum/callisto.git`.
* `git submodule update --init`

**2. Compile all projects**

- `zig build -Drelease-fast`