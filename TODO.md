- Don't show any tweets on first poll after authenticating.
  - Could do something like not show tweets older than our last poll time.
    At startup we set last poll time to 'now'. Each tweet has a created_at
    that we can parse with format %a %b %d %T %z %Y. If we did this then we
    could drop the ignore_tweets logic as we could use the same logic. This
    would improve new follow behaviour as well as it would mean you could
    follow accounts via the website.
