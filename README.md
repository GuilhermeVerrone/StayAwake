# StayAwake

**Mantenha seu status "Disponível" no macOS sem instalar nada obscuro, sem mexer o
seu mouse e sem efeito colateral nenhum.** Um app de barra de menu de 120 KB,
em Swift puro, sem dependências.

![macOS](https://img.shields.io/badge/macOS-12%2B-black)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![Sem dependências](https://img.shields.io/badge/depend%C3%AAncias-0-brightgreen)
![License](https://img.shields.io/badge/license-MIT-blue)

---

## O problema

Teams, Slack, Discord e afins não têm API de presença local. Eles decidem que você
está "Ausente" lendo o **`HIDIdleTime` do macOS** — o tempo desde o seu último
input real de teclado ou mouse.

O `caffeinate` do sistema **não** resolve isso: ele segura o sono da tela, mas não
zera o contador de input. Por isso você fica Ausente mesmo com o `caffeinate`
rodando. O StayAwake ataca os dois pontos.

## Como funciona

| Mecanismo | O que faz |
|---|---|
| **Pulso de mouse** | Posta um `mouseMoved` via `CGEvent` na coordenada **exata onde o cursor já está**. Zera o `HIDIdleTime` sem deslocar o cursor, sem tecla e sem clique. |
| **Assertion de energia** | `kIOPMAssertionTypePreventUserIdleDisplaySleep` via IOKit, para a tela não dormir — tela bloqueada marca Ausente independente do idle. |

E o detalhe que importa: **ele só age depois de um tempo real sem uso.** Um
heartbeat de 10s lê o `HIDIdleTime` direto do IOKit e só pulsa se a ociosidade
passar do limiar que você escolher. Enquanto você está digitando, ele gera
exatamente zero eventos.

## Por que não uma tecla (a parte interessante)

A primeira versão disto pressionava **F15**, o truque clássico de "tecla sem
efeito". Ficou um bug ótimo: **o brilho da tela subia sozinho ao longo do dia.**

Em teclado Apple, `F14`/`F15` (keycodes 107/113) são **brilho −/+**, e o macOS
honra isso. Cada pulso subia um nível. Em um dia de trabalho, brilho no máximo.

As alternativas também não servem:

| Tecla | Por que não |
|---|---|
| `F15` (113) | Brilho **+** em teclado Apple |
| `F14` (107) | Brilho **−** |
| `Clear` (71) | É o "NumLock" do macOS: alterna num lock de verdade e quebra o teclado numérico |
| Modificadores | Um `Shift` perdido no meio da sua digitação |

O `mouseMoved` de deslocamento zero é melhor que qualquer tecla porque
**não existe estado algum sendo alternado**. É um evento HID puro dizendo
"o mouse está em (x, y)", onde (x, y) é onde ele já estava.

## Instalação

Requer Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/GuilhermeVerrone/StayAwake.git
cd StayAwake
./build.sh
cp -R "build/StayAwake.app" ~/Applications/
open ~/Applications/StayAwake.app
```

Compilar você mesmo também evita o aviso de Gatekeeper que apareceria num
binário baixado de terceiro.

### Permissão de Acessibilidade

Na primeira ativação o macOS vai pedir **Acessibilidade**:

> Ajustes do Sistema › Privacidade e Segurança › Acessibilidade → marque o StayAwake

Sem isso o `CGEvent` é descartado **em silêncio** — o app parece rodar e não faz nada.

> **Nota:** o `build.sh` assina o bundle ad-hoc (`codesign --sign -`) justamente
> para a permissão não ser revogada a cada rebuild. Sem certificado de
> desenvolvedor, ainda assim o `cdhash` muda a cada build, então em alguns
> rebuilds pode ser necessário desmarcar e remarcar o app na lista.

## Uso

Tudo pelo ícone de copo na barra superior:

| Item | O que faz |
|---|---|
| **Ativar agora** (⌘A) | Liga para esta sessão. Ícone preenchido = ativo |
| **Pulsar após** | Limiar de ociosidade: 30s, 1min, 2min ou 4min sem uso |
| **Impedir tela de dormir** | Liga/desliga a assertion de energia |
| **Agendamento** | Faixa de horário, ex. 08h–18h, com opção de só dias de semana |
| **Abrir no login** | Registra via `SMAppService` (aparece em Itens de Início) |

O app **abre no login já parado**, de propósito: a ativação manual vive só na
execução atual e nunca é salva em disco. Ele sobe, fica esperando, e só roda
quando você manda — ou quando a agenda manda.

O agendamento aceita faixa que cruza a meia-noite (`22h–06h`), e manual e agenda
são independentes: ⌘A ativa fora do horário sem mexer na configuração.

## Verificando você mesmo

Não confie no README. Deixe a máquina parada e observe o contador real:

```bash
while :; do ioreg -c IOHIDSystem | awk -F'= ' '/HIDIdleTime/ {printf "idle=%ds\n", $2/1000000000; exit}'; sleep 5; done
```

Com o app ativo, o idle sobe até o limiar, zera e sobe de novo — um dente de
serra. Desligado, sobe sem parar. E para confirmar que a tela está segura:

```bash
pmset -g assertions | grep StayAwake
```

## O que ele NÃO faz

Deliberadamente honesto, porque a alternativa é você se decepcionar depois:

- **Não vence monitoramento de produtividade.** Hubstaff, Time Doctor, ActivTrak e
  parentes não olham idle: contam volume de teclas, janela em foco, screenshot.
  Um pulso por minuto não se parece com trabalho para esse tipo de software.
- **Não sobrepõe status manual.** Se você marcar "Ocupado" ou "Não perturbe",
  o app não interfere.
- **Não cria presença de app fechado.** Idle zerado não loga você em nada.
- **Não mexe em status de reunião/calendário**, que vem do servidor.

## Licença

MIT — veja [LICENSE](LICENSE).
