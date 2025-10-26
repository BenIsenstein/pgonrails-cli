# PG On Rails CLI

This is a bash script for creating a [Supabase](https://supabase.com/) project with [PG On Rails](https://github.com/BenIsenstein/pgonrails), deployed on [Railway](https://railway.com/), with CI/CD configured, from your terminal, **hands-free**, in **minutes**.

*"PG On Rails | Self-hosted Supabase. Amazing developer experience."*

Prefer to use Railway's web UI?

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/complete-supabase-nextjs-frontend?referralCode=benisenstein&utm_medium=integration&utm_source=template&utm_campaign=generic)

## Prerequisites

- Linux/MacOS/WSL
- GitHub account
- Railway account
- Granted consent for Railway to use GitHub on your behalf
- Railway API token in `.env` file (see `.env.example`)

## Quickstart

Copy `.env.example` into a `.env` file. It will be gitignored.

Add your Railway API token to `RAILWAY_TOKEN`.

Run `./start.sh`

It will take about 5 minutes, and will print progress updates.

Clone your new GitHub repo.

`git clone YOUR_REPO`

Run your Supabase project locally:

`cd YOUR_REPO && ./setup.sh && docker compose up`

Commit new code and watch your project deploy continuously :)

## Learn more

To learn more about PG On Rails visit the [main GitHub repo.](https://github.com/BenIsenstein/pgonrails)