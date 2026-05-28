# Architecture

The main entry point is `src/simulator.py`.

At a high level:

1. `InputProperties` reads the JSON input.
2. `ModelParameters` loads shared parameter dictionaries and data files.
3. `Network` creates nodes and dynamic compartment indices.
4. Treatment models distribute vaccines and antivirals.
5. Disease models advance compartment states.
6. Travel models move exposure pressure across nodes.
7. `Writer` emits daily outputs and metadata.

## Model Families

- Disease models live in `src/models/disease/`.
- Travel models live in `src/models/travel/`.
- Treatment and intervention models live in `src/models/treatments/`.
- Base classes and shared data structures live in `src/baseclasses/`.

## Dynamic Compartments

The active `Compartments` enum is created from the input JSON compartment list.
This makes the same population storage work for SEIRS, SEITRS, SEIHRD, and
future compartment sets. Code that accesses compartments should use
`Compartments.S.value`, `Compartments.T.value`, and similar labels rather than
hard-coded indices.
