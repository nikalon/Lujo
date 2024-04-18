# Lujo
Interpreted programming language based on a subset of Lox.

This language was implemented in Zig and is based on the book [Crafting Interpreters](https://craftinginterpreters.com/).

# Building
To build this project do the following steps in order:

1. Install [Zig compiler](https://ziglang.org/). This code was made specifically for version `0.11.0`, so it may not work in newer versions.
2. Clone this repository.
3. Execute the following command in a shell: `zig build`

The executable will be generated in `zig-out/bin` directory.

## TODO
- Add garbage collector
- Fix closures not working as intended in some circumstances

## Features that will not be implemented
- Classes
- Interfaces
