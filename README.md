# fetch_images

A simple Ruby script for downloading all images from a Fantia article.

## Requirements

- Ruby 3.0 or later
- The [`nokogiri`](https://nokogiri.org/) gem (`gem install nokogiri`)

## Usage

```
ruby fantia_fetcher.rb [options] ARTICLE_URL
```

### Options

- `-o`, `--output DIR` – Directory to save the downloaded images (default: `images`).
- `-c`, `--cookie COOKIE` – Optional `Cookie` header for requests to access members-only posts.
- `-v`, `--[no-]verbose` – Enable verbose logging to see progress messages.

### Example

```
ruby fantia_fetcher.rb -o downloads -v https://fantia.jp/posts/123456
```

This command downloads all images referenced by the article into the `downloads` directory, showing progress logs.
