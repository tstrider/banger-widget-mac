# Banger Widget for Mac

**A to-do list that lives on your desktop and throws a party every time you finish something.**

Check off a task and your screen fills with confetti, a sound plays, and your trackpad gives a
little thump. Finish the last task of the day and the party gets bigger. Clear your list
several days in a row and it gets bigger again.

![A completion firing on the desktop](docs/images/celebration.png)

---

## What it's for

Most to-do apps treat finishing a task as nothing special. You tick a box, the line goes grey,
and that's it. Banger makes finishing things feel good, so you want to do the next one.

It does two things:

1. **Your list is always in view.** It sits on your desktop as a widget. You never have to open
   an app to see what's left, so you don't forget it's there.
2. **You get an instant reward.** The moment you check something off, you see it, hear it and
   feel it. Not a second later. Right then.

It was built with ADHD in mind, where "out of sight, out of mind" is real and a reward only
works if it's immediate. But anyone who likes a bit of a kick for getting things done will
enjoy it.

---

## How you use it

**Adding tasks.** Any of these work:

- Press **⌃⌥⌘N** (Control, Option, Command and N) from any app. A text box appears in the
  middle of your screen. Type the task and press Return.
- Click the **+** button on the widget.
- Type in Terminal: `bangerctl add "Call the realtor"`
- Let an AI assistant add them for you (see below).

**Checking them off.** Click the circle next to a task on the widget. That's it. The party
starts on its own.

**Reading a long task.** Click the words of a task to see the full text in a small card.

**Seeing a long list.** When you have more tasks than fit, two buttons appear under the list.
Click **more** to slide down to the rest. Click **done** (or **above**) to slide back up. Five
minutes after your last click, the list slides back to where it started on its own.

**Each day starts fresh.** Banger keeps one list per day. There are no due dates, projects or
future days. At 2 a.m. the day rolls over, and tomorrow starts with a new list. If you cleared
every task, your streak goes up by one.

**Your finished tasks move to the top.** When you check one off, it pops up to join the rest
of your finished tasks, in the order you did them. What's left to do stays together below.

---

## The fun parts

**The big celebration.** Confetti and paper burst across the whole screen, with a sound and a
thump through the trackpad. It comes in levels:

- a normal task gets a normal burst,
- the last task of the day gets a bigger one,
- the last task of the day while you're on a streak gets the biggest.

**The widget has its own animations too.**

- **Checking a box** makes the circle punch in, the tick draw itself, a few amber sparks fly,
  and a gold light run once around the edge of the widget. The count at the top updates at the
  same moment.
- **Finished tasks pop to the top.** The task fades from its old spot and bounces into its new
  one, while the tasks still to do slide down to make room.
- **The last task gets a stamp** so you know it's the one that finishes the day.
- **The streak flame** grows the longer your streak runs, and turns urgent late in the day if
  you haven't cleared your list yet.

---

## Let an AI assistant manage your list

Everything Banger knows is stored in one simple file, and the `bangerctl` command can read and
change it. That means any AI assistant that can run a Terminal command (Claude, for example)
can fill in your list each morning from what you told it, or read it back to you. There's no
account, no login and no setup.

```sh
bangerctl add "Call the realtor"    --source iris
bangerctl add "Export the invoices" --source iris
bangerctl list --json
```

`--source` records who added the task. The widget shows it on each row, so you can tell your
own tasks from the ones your assistant added.

**Give your assistant [`docs/agent-guide.md`](docs/agent-guide.md).** It's written for an AI to
read and has everything it needs.

One rule matters more than the rest: **always change the list through `bangerctl`, never by
writing to the file directly.** Writing to the file directly can leave it half-written if
something reads it at the same moment.

---

## What's included

- **The widget.** Your checklist on the desktop. The large size shows nine tasks and is the one
  to use. The medium and small sizes work, but they show only a few at a time. A longer list
  scrolls on any size.
- **The Banger app.** It runs quietly in the background with no window, no Dock icon and no
  menu bar icon. It watches your list and throws the party when something gets checked off.
- **`bangerctl`.** A Terminal command for adding, checking off and listing tasks.

---

## Before you install

- You need **macOS 26 or later** on an Apple silicon Mac.
- You need **Xcode 26 or later**, because you build it yourself.
- You need **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**, a small tool that sets up the
  Xcode project.
- **There's no ready-made download.** This project has no paid Apple developer account, so
  there's no signed app to double-click. The install script builds it on your Mac. If that's a
  dealbreaker, fair enough.

## Install

```sh
git clone https://github.com/tstrider/banger-widget-mac.git
cd banger-widget-mac
./tools/install.sh
```

This builds everything, puts `Banger.app` in your Applications folder, installs `bangerctl`,
and starts the app. It takes a minute or two.

**You won't see a window or a Dock icon. That's normal.** The app runs in the background.

### Then two quick steps by hand

macOS doesn't let a script do these, so you have to.

**1. Put the widget on your desktop.** Right-click an empty part of the desktop, choose
**Edit Widgets**, find **Banger**, and drag the **large** size where you want it. If Banger
isn't in the list, open the app once and look again.

**2. Make it start when you log in.** Go to System Settings, then General, then Login Items.
Click **+** and add `/Applications/Banger.app`. If you skip this, the list still shows after a
restart, but the celebrations stop until you open the app again.

### Try it

```sh
bangerctl add "first one"
bangerctl done 1
```

You should get confetti.

### Uninstall

```sh
./tools/install.sh --uninstall
```

This quits the app and removes it. Your task list is left alone.

---

## Settings

By default the day ends at **2 a.m. Chicago time**. It's 2 a.m. rather than midnight so that
finishing a task at 12:40 a.m. still counts for the day you were working on.

To change it, create the file `~/Library/Application Support/Banger/config.json`:

```json
{
  "rolloverHour": 4,
  "timeZone": "Europe/London"
}
```

Use a city-style time zone name like the one above, so daylight saving time is handled for
you. Restart the app after you edit the file. If the file is missing or has a mistake in it,
Banger uses the defaults.

---

## Licence

**MIT.** See [`LICENSE`](LICENSE).

You can use it, change it, pull the celebration out and put it in something else, or sell it.
Just keep the copyright line.

The sounds and the confetti were made for this project. There are no image or audio files from
anywhere else, so the licence covers everything here.
