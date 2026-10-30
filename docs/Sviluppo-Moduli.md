# Lavorare sui moduli anche in chat diverse

Una chat per modulo, nello stesso progetto Assistente IT, rende piu facile
seguire il lavoro. Il repository contiene lo stato condiviso; non occorre
trascrivere tutta la cronologia di una chat precedente.

All'inizio di una nuova chat indicare:

> Repository minirusty97/RC_OPBG_4. Lavora sul modulo [nome] partendo dal main
> attuale. Leggi AGENTS.md, docs/STATO-PROGETTO.md e la documentazione del
> modulo. Obiettivo: [modifica richiesta]. Mantieni accesso delegato dal
> wrapper, distinzione lettura/scrittura e integrazione GLPI esistente.

Per modifiche comuni ad accesso, wrapper, GLPI, BitLocker, installer o release
usare una chat di integrazione. Due chat possono preparare rami separati;
le modifiche ai file comuni e la pubblicazione vanno coordinate. Dopo il
merge di un ramo, l'altro deve ripartire dal main aggiornato, risolvere i
conflitti e ripetere i controlli pertinenti. Non sovrascrivere main con una
copia locale o una versione ricordata da un'altra chat.

## Contratto dei moduli

- Ogni modulo dichiara ID, nome, entry point, ambiti di lettura e scrittura
  nel manifest. `RequireAllReadPermissions` richiede tutti gli ambiti di
  lettura dichiarati quando il modulo ne dipende congiuntamente.
- `UsesAppSettings` condivide ConfigPath e EnvPath; `UsesGraphAccess` riceve
  il risultato verificato dell'accesso. Il modulo non autentica l'utente.
- Le finestre girano in STA nello stesso processo del wrapper; le letture
  lunghe usano un worker distinto. Il timer viene fermato prima di consumare
  il risultato o aprire conferme, evitando completamenti ripetuti.
- La UI impedisce scritture in sola lettura; il backend ripete il controllo
  e verifica tenant, app e account. Le scritture richiedono un piano privato
  breve, rilettura degli oggetti e conferma esplicita.
- `DeviceModules.Core.psm1` condivide paginazione Graph, integrazione Intune /
  GLPI e protezione dei CSV. I backend dei moduli conservano logica e piani.
- `DeviceModules.UI.ps1` condivide filtri, contatori, dettagli, resoconti e
  aspetto dei nuovi moduli. Computer Explorer mantiene la sua interfaccia;
  la conferma di eliminazione e condivisa in `ComputerExplorer.Removal.UI.ps1`.
- I nuovi file runtime vanno aggiunti alla allowlist di `build/Build-AssistenteIT.ps1`.
  Aggiungere test pertinenti di backend e finestre native.

Le impostazioni nuove usano valori predefiniti se la configurazione esistente
non contiene ancora la sezione. Il salvataggio conserva le altre impostazioni
e i token lasciati vuoti. Aggiornare documentazione e `STATO-PROGETTO.md` a
lavoro concluso, distinguendo controlli con dati sintetici e verifiche aziendali.
