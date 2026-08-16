CLOCK.R4X
=========

CLOCK.R4X ist die gehostete Desktop-Uhr-App.

Projektstruktur:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` pinnt SDK und R4OS-Librarybindings als Pakete.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.
- `Settings.R4S` mappt lokale Checkouts, DevKit und Artefaktausgabe.

Build:

    Build.bat

Ergebnis:

    D:\R4OS\Artifacts\Modules\Clock\CLOCK.R4X

Alle Pfade in `Settings.R4S` beginnen am Repository-Root und duerfen relativ
oder absolut angegeben werden. Der Build verwendet die gepinnte
`r4std_zig_binding`-Paketkante; er referenziert kein festes Nachbarrepository.

Contract:
- R4XStart-Entry: `clock_main`
- App-Klasse: `gui`
- R4L-Imports: `R4SYS:Query:1`, `R4DESK:Query:1`, `R4DRAW:Query:1`,
  `R4NET:Query:1`, `R4DEV:Query:1`, `R4STD:TIME_V1:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\CLOCK.R4X`

Herkunft und Transfergrenzen stehen in `PROVENANCE.txt`.
