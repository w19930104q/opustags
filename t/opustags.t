#!/usr/bin/env perl

use strict;
use warnings;
use utf8;

use Test::More tests => 79;
use Test::Deep qw(cmp_deeply re);

use Digest::MD5;
use File::Basename;
use File::Copy;
use IPC::Open3;
use List::MoreUtils qw(any);
use Symbol 'gensym';

my $opustags = '../opustags';
BAIL_OUT("$opustags does not exist or is not executable") if (! -x $opustags);

my $is_utf8;
open(my $ctype, 'locale -k LC_CTYPE |');
while (<$ctype>) { $is_utf8 = 1 if (/^charmap="UTF-?8"$/i) }
close($ctype);
BAIL_OUT("this test must be run from an UTF-8 environment") unless $is_utf8;

sub opustags {
	my %opt;
	%opt = %{pop @_} if ref $_[-1];
	my ($pid, $pin, $pout, $perr);
	$perr = gensym;
	$pid = open3($pin, $pout, $perr, $opustags, @_);
	binmode($pin, $opt{mode} // ':utf8');
	binmode($pout, $opt{mode} // ':utf8');
	binmode($perr, ':utf8');
	local $/;
	print $pin $opt{in} if defined $opt{in};
	close $pin;
	my $out = <$pout>;
	my $err = <$perr>;
	waitpid($pid, 0);
	[$out, $err, $?]
}

####################################################################################################
# Tests related to the overall opustags executable, like the help message.
# No Opus file is manipulated here.

is_deeply(opustags(), ['', <<EOF, 512], 'no options is a failure');
error: No arguments specified. Use -h for help.
EOF

my $help = opustags('--help');
$help->[0] =~ /^([^\n]*+)/;
my $version = $1;
like($version, qr/^opustags version (\d+\.\d+\.\d+)/, 'get the version string');

my $expected_help = qr{opustags version .*\n\nUsage: opustags --help\n};
cmp_deeply(opustags('--help'), [re($expected_help), '', 0], '--help displays the help message');
cmp_deeply(opustags('-h'), [re($expected_help), '', 0], '-h displays the help message too');

is_deeply(opustags('--derp'), ['', <<"EOF", 512], 'unrecognized option shows an error');
error: Unrecognized option '--derp'.
EOF

is_deeply(opustags('../opustags'), ['', <<"EOF", 256], 'not an Ogg stream');
../opustags: error: Input is not a valid Ogg file.
EOF

####################################################################################################
# Test the main features of opustags on an Ogg Opus sample file.

sub md5 {
	my ($file) = @_;
	open(my $fh, '<', $file) or return;
	my $ctx = Digest::MD5->new;
	$ctx->addfile($fh);
	$ctx->hexdigest
}

is(md5('gobble.opus'), '111a483596ac32352fbce4d14d16abd2', 'the sample is the one we expect');
is_deeply(opustags('gobble.opus'), [<<'EOF', '', 0], 'read the initial tags');
encoder=Lavc58.18.100 libopus
EOF

unlink('out.opus');
my $previous_umask = umask(0022);
is_deeply(opustags(qw(gobble.opus -o out.opus)), ['', '', 0], 'copy the file without changes');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'the copy is faithful');
is((stat 'out.opus')[2] & 0777, 0644, 'apply umask on new files');
umask($previous_umask);

# empty out.opus
{ my $fh; open($fh, '>', 'out.opus') and close($fh) or die }
is_deeply(opustags(qw(gobble.opus -o out.opus)), ['', <<'EOF', 256], 'refuse to override');
gobble.opus: error: 'out.opus' already exists. Use -y to overwrite.
EOF
is(md5('out.opus'), 'd41d8cd98f00b204e9800998ecf8427e', 'the output wasn\'t written');

is_deeply(opustags(qw(gobble.opus -o /dev/null)), ['', '', 0], 'write to /dev/null');

chmod(0604, 'out.opus');
is_deeply(opustags(qw(gobble.opus -o out.opus --overwrite)), ['', '', 0], 'overwrite');
is(md5('out.opus'), '111a483596ac32352fbce4d14d16abd2', 'successfully overwritten');
is((stat 'out.opus')[2] & 0777, 0604, 'overwriting preserves output file\'s mode');

chmod(0700, 'out.opus');
is_deeply(opustags(qw(--in-place out.opus -a A=B --add=A=C --add), "TITLE=Foo Bar",
                   qw(--delete A --add TITLE=七面鳥 --set encoder=whatever -s 1=2 -s X=1 -a X=2 -s X=3)),
          ['', '', 0], 'complex tag editing');
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'check the footprint');
is((stat 'out.opus')[2] & 0777, 0700, 'in-place editing preserves file mode');

is_deeply(opustags('out.opus'), [<<'EOF', '', 0], 'check the tags written');
A=B
A=C
TITLE=Foo Bar
TITLE=七面鳥
encoder=whatever
1=2
X=1
X=2
X=3
EOF

is_deeply(opustags(qw(out.opus -d A -d foo -s X=4 -a TITLE=gobble -d title=七面鳥)), [<<'EOF', '', 0], 'dry editing');
TITLE=Foo Bar
encoder=whatever
1=2
X=4
TITLE=gobble
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(-i out.opus -a fatal=yes -a FOO -a BAR)), ['', <<'EOF', 512], 'bad tag with --add');
error: Comment does not contain an equal sign: FOO.
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags('out.opus', '-D', '-a', "X=foobar\tquux"), [<<'END_OUT', <<'END_ERR', 0], 'control characters');
X=foobar	quux
END_OUT
warning: Some tags contain control characters.
END_ERR

is_deeply(opustags('out.opus', '-D', '-a', "X=foo\n\nbar"), [<<'END_OUT', '', 0], 'newline characters');
X=foo
	
	bar
END_OUT

is_deeply(opustags(qw(-i out.opus -s fatal=yes -s FOO -s BAR)), ['', <<'EOF', 512], 'bad tag with --set');
error: Comment does not contain an equal sign: FOO.
EOF
is(md5('out.opus'), '66780307a6081523dc9040f3c47b0448', 'the file did not change');

is_deeply(opustags(qw(out.opus --delete-all -a OK=yes)), [<<'EOF', '', 0], 'delete all');
OK=yes
EOF

is_deeply(opustags(qw(out.opus --set-all -a A=B -s X=Z -d OK), {in => <<'END_IN'}), [<<'END_OUT', '', 0], 'set all');
OK=yes again
ARTIST=七面鳥

A=A
X=Y
#IGNORE=COMMENTS
END_IN
OK=yes again
ARTIST=七面鳥
A=A
X=Y
A=B
X=Z
END_OUT

is_deeply(opustags(qw(out.opus -S), {in => <<'END_IN'}), [<<'END_OUT', <<'END_ERR', 256], 'set all with bad tags');
whatever
wrong=yes
END_IN
END_OUT
error: Malformed tag: whatever
END_ERR

sub slurp {
	my ($filename) = @_;
	local $/;
	open(my $fh, '<', $filename);
	binmode($fh);
	my $data = <$fh>;
	$data
}

my $data = slurp 'out.opus';
is_deeply(opustags('-', '-o', '-', {in => $data, mode => ':raw'}), [$data, '', 0], 'read opus from stdin and write to stdout');

unlink('out.opus');

# Test --in-place
unlink('out2.opus');
copy('gobble.opus', 'out.opus');
is_deeply(opustags(qw(out.opus --add BAR=baz -o out2.opus)), ['', '', 0], 'process multiple files with --in-place');
is_deeply(opustags(qw(--in-place --add FOO=bar out.opus out2.opus)), ['', '', 0], 'process multiple files with --in-place');
is(md5('out.opus'), '30ba30c4f236c09429473f36f8f861d2', 'the tags were added correctly (out.opus)');
is(md5('out2.opus'), '0a4d20c287b2e46b26cb0eee353c2069', 'the tags were added correctly (out2.opus)');

unlink('out.opus');
unlink('out2.opus');

####################################################################################################
# Interactive edition

$ENV{EDITOR} = 'sed -i -e y/aeiou/AEIOU/ `sleep 0.1`';
is_deeply(opustags('gobble.opus', '-eo', "'screaming !'.opus"), ['', '', 0], 'edit a file with EDITOR');
is(md5("'screaming !'.opus"), '56e85ccaa83a13c15576d75bbd6d835f', 'the tags were modified');

$ENV{EDITOR} = 'true';
is_deeply(opustags('-ie', "'screaming !'.opus"), ['', "Cancelling edition because the tags file was not modified.\n", 256], 'close -e without saving');
is(md5("'screaming !'.opus"), '56e85ccaa83a13c15576d75bbd6d835f', 'the tags were not modified');

$ENV{EDITOR} = 'false';
is_deeply(opustags('-ie', "'screaming !'.opus"), ['', "'screaming !'.opus: error: Child process exited with 1\n", 256], 'editor exiting with an error');
is(md5("'screaming !'.opus"), '56e85ccaa83a13c15576d75bbd6d835f', 'the tags were not modified');

unlink("'screaming !'.opus");

####################################################################################################
# Test muxed streams

system('ffmpeg -loglevel error -y -i gobble.opus -c copy -map 0:0 -map 0:0 -shortest muxed.ogg') == 0
	or BAIL_OUT('could not create a muxed stream');

is_deeply(opustags('muxed.ogg'), ['', <<'END_ERR', 256], 'muxed streams detection');
muxed.ogg: error: Muxed streams are not supported yet.
END_ERR

unlink('muxed.ogg');

####################################################################################################
# Locale

my $locale = 'en_US.iso88591';
my @all_locales = split(' ', `locale -a`);

SKIP: {
skip "locale $locale is not present", 5 unless (any { $_ eq $locale } @all_locales);

opustags(qw(gobble.opus -a TITLE=七面鳥 -a ARTIST=éàç -o out.opus -y));

local $ENV{LC_ALL} = $locale;
local $ENV{LANGUAGE} = '';

is_deeply(opustags(qw(-S out.opus), {in => <<"END_IN", mode => ':raw'}), [<<"END_OUT", '', 0], 'set all in ISO-8859-1');
T=\xef\xef\xf6
END_IN
T=\xef\xef\xf6
END_OUT

is_deeply(opustags('-i', 'out.opus', "--add=I=\xf9\xce", {mode => ':raw'}), ['', '', 0], 'write tags in ISO-8859-1');

is_deeply(opustags('out.opus', {mode => ':raw'}), [<<"END_OUT", <<"END_ERR", 256], 'read tags in ISO-8859-1 with incompatible characters');
encoder=Lavc58.18.100 libopus
END_OUT
out.opus: error: Invalid or incomplete multibyte or wide character. See --raw.
END_ERR

is_deeply(opustags(qw(out.opus -d TITLE -d ARTIST), {mode => ':raw'}), [<<"END_OUT", '', 0], 'read tags in ISO-8859-1');
encoder=Lavc58.18.100 libopus
I=\xf9\xce
END_OUT

$ENV{LC_ALL} = '';

is_deeply(opustags('out.opus'), [<<"END_OUT", '', 0], 'read tags in UTF-8');
encoder=Lavc58.18.100 libopus
TITLE=七面鳥
ARTIST=éàç
I=ùÎ
END_OUT

unlink('out.opus');
}

####################################################################################################
# Raw edition

is_deeply(opustags(qw(-S gobble.opus -o out.opus --raw -a), "U=\xFE", {in => <<"END_IN", mode => ':raw'}), ['', '', 0], 'raw set-all with binary data');
T=\xFF
END_IN

is_deeply(opustags(qw(out.opus --raw), { mode => ':raw' }), [<<"END_OUT", '', 0], 'raw read');
T=\xFF
U=\xFE
END_OUT

unlink('out.opus');

####################################################################################################
# Multiple-page tags
#
# The fixed sample multipage.opus carries an OpusTags packet spanning 3 pages, followed by regular
# audio pages. Rewriting its tags must only touch the tags pages: every other page keeps its exact
# bytes, order, boundaries, sequence number, granule position, and CRC.

my $TAGS_PAGES = 3; # pages 1..3 of multipage.opus are the OpusTags packet.

sub ogg_pages {
	my ($file) = @_;
	open(my $fh, '<', $file) or die "cannot open $file: $!";
	binmode($fh);
	local $/;
	my $data = <$fh>;
	my @pages;
	my $off = 0;
	while ($off < length($data)) {
		die "lost Ogg sync at byte $off in $file" unless substr($data, $off, 4) eq 'OggS';
		my $nseg = ord(substr($data, $off + 26, 1));
		my $segtab = substr($data, $off + 27, $nseg);
		my $body_len = 0;
		$body_len += ord($_) for split(//, $segtab);
		my $header_len = 27 + $nseg;
		push(@pages, {
			offset => $off,
			header => substr($data, $off, $header_len),
			body   => substr($data, $off + $header_len, $body_len),
			type   => ord(substr($data, $off + 5, 1)),
			gran   => unpack('Q<', substr($data, $off + 6, 8)),
			serial => unpack('V',  substr($data, $off + 14, 4)),
			seq    => unpack('V',  substr($data, $off + 18, 4)),
			crc    => unpack('V',  substr($data, $off + 22, 4)),
			segtab => [map { ord($_) } split(//, $segtab)],
			total  => $header_len + $body_len,
		});
		$off += $header_len + $body_len;
	}
	return @pages;
}

# Compare the pages that are not part of the OpusTags packet (the OpusHead page and every audio
# page). When $check_offsets is true, also require identical byte offsets, which is only possible
# when the tags region kept its exact size. Returns undef on success, otherwise an explanation.
sub non_tags_pages {
	my ($original, $edited, $check_offsets) = @_;
	my @a = ogg_pages($original);
	my @b = ogg_pages($edited);
	return "page count differs ($#a vs $#b)" unless @a == @b;
	for my $i (0 .. $#a) {
		next if $i >= 1 && $i <= $TAGS_PAGES; # the tags pages are allowed to change
		my ($pa, $pb) = ($a[$i], $b[$i]);
		return "page $i offset differs"           if $check_offsets && $pa->{offset} != $pb->{offset};
		return "page $i header bytes differ"       unless $pa->{header} eq $pb->{header};
		return "page $i body bytes differ"         unless $pa->{body}   eq $pb->{body};
		return "page $i sequence number differs"   unless $pa->{seq}    == $pb->{seq};
		return "page $i granule position differs"  unless $pa->{gran}   == $pb->{gran};
		return "page $i flags differ"              unless $pa->{type}   == $pb->{type};
		return "page $i lacing differs"            unless join(',', @{$pa->{segtab}})
		                                                     eq join(',', @{$pb->{segtab}});
	}
	return;
}

my $fixture_tag = "DATA=" . ("x" x 200) . "\n";
is(scalar(ogg_pages('multipage.opus')), 6, 'the multi-page fixture has 6 pages');
is_deeply(opustags('multipage.opus'), [$fixture_tag x 650, '', 0], 'read multi-page tags');

# Shrink the tags: the packet is padded back to its exact original size.
copy('multipage.opus', 'out.opus');
is_deeply(opustags(qw(out.opus -i -D -a), 'TITLE=shrunk'), ['', '', 0], 'shrink multi-page tags');
ok(!defined non_tags_pages('multipage.opus', 'out.opus', 1),
   'shrinking leaves every non-tags page byte-identical at the same offset');
is(-s 'out.opus', -s 'multipage.opus', 'shrinking preserves the total file size');
is_deeply(opustags('out.opus'), [<<"EOF", '', 0], 'the shrunk tags are readable');
TITLE=shrunk
EOF

# Grow the tags while they still fit in the same 3 pages: no renumbering, no boundary change. The
# tags region gets larger, so the audio pages shift in the file but stay byte-identical.
copy('multipage.opus', 'grow.opus');
my @grown = map { "GROW$_=" . ('y' x 100) } 1 .. 12;
is_deeply(opustags('grow.opus', '-i', map { ('-a', $_) } @grown),
          ['', '', 0], 'grow multi-page tags within the original pages');
ok(!defined non_tags_pages('multipage.opus', 'grow.opus', 0),
   'growing leaves every non-tags page byte-identical with unchanged sequence numbers');
is(scalar(ogg_pages('grow.opus')), scalar(ogg_pages('multipage.opus')),
   'growing does not add or remove any page');

# Idempotency: applying the exact same edit twice yields byte-identical files.
copy('multipage.opus', 'idem1.opus');
copy('multipage.opus', 'idem2.opus');
opustags(qw(idem1.opus -i -D -a), 'TITLE=same');
opustags(qw(idem2.opus -i -D -a), 'TITLE=same');
is(md5('idem1.opus'), md5('idem2.opus'), 'repeating the same edit is idempotent');

# Rewriting a file with the same tags it already contains reproduces it byte for byte.
copy('multipage.opus', 'noop.opus');
is_deeply(opustags(qw(noop.opus -i)), ['', '', 0], 'rewrite multi-page tags without changes');
is(md5('noop.opus'), md5('multipage.opus'), 'a no-op rewrite is byte-identical');

# Overflow: tags that need more pages than the original are refused, and the original file is
# restored (the temporary partial file is removed). 30000 lines make a ~210 KiB packet, which
# needs 4 pages while the fixture only has 3 tags pages.
copy('multipage.opus', 'overflow.opus');
my $overflow_md5 = md5('overflow.opus');
my $overflow_result = opustags(qw(-S -i overflow.opus),
                               {in => "DATA=z\n" x 30000, mode => ':raw'});
is($overflow_result->[0], '', 'overflow produces no stdout');
like($overflow_result->[1], qr/do not fit in the original header pages/,
     'refuse tags that would change the pagination');
is($overflow_result->[2], 256, 'overflow exits with a failure status');
is(md5('overflow.opus'), $overflow_md5, 'the original file is restored after a failed rewrite');
ok(!(glob 'overflow.opus*.part'), 'no partial file is left after a failed rewrite');

unlink('out.opus', 'grow.opus', 'idem1.opus', 'idem2.opus', 'noop.opus', 'overflow.opus');

####################################################################################################
# Cover arts

is_deeply(opustags(qw(-D --set-cover pixel.png gobble.opus -o out.opus)), ['', '', 0], 'set the cover');
is_deeply(opustags(qw(--output-cover out.png out.opus)), [<<'END_OUT', '', 0], 'extract the cover');
METADATA_BLOCK_PICTURE=AAAAAwAAAAlpbWFnZS9wbmcAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAEWJUE5HDQoaCgAAAA1JSERSAAAAAQAAAAEIAgAAAJB3U94AAAAMSURBVAjXY/j//z8ABf4C/tzMWecAAAAASUVORK5CYII=
END_OUT
is(md5('out.png'), md5('pixel.png'), 'the extracted cover is identical to the one set');
unlink('out.opus');
unlink('out.png');

is_deeply(opustags(qw(-D --set-cover - gobble.opus), { in => "GIF8 x" }), [<<'END_OUT', '', 0], 'read the cover from stdin');
METADATA_BLOCK_PICTURE=AAAAAwAAAAlpbWFnZS9naWYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAZHSUY4IHg=
END_OUT

####################################################################################################
# Vendor string

is_deeply(opustags(qw(--vendor gobble.opus)), ["Lavf58.12.100\n", '', 0], 'print the vendor string');

is_deeply(opustags(qw(--set-vendor opustags gobble.opus -o out.opus)), ['', '', 0], 'set the vendor string');
is_deeply(opustags(qw(--vendor out.opus)), ["opustags\n", '', 0], 'the vendor string was updated');
unlink('out.opus');

####################################################################################################
# Multi-line tags

is_deeply(opustags(qw(--set-all gobble.opus -o out.opus), { in => "MULTILINE=one\n\ttwo\nSIMPLE=three\n" }), ['', '', 0], 'parses continuation lines');
is_deeply(opustags(qw(out.opus -z)), ["MULTILINE=one\ntwo\0SIMPLE=three\0", '', 0], 'delimits output with NUL on -z');
unlink('out.opus');

is_deeply(opustags(qw(--set-all gobble.opus -o out.opus -z), { in => "MULTILINE=one\ntwo\0SIMPLE=three\0" }), ['', '', 0], 'delimits input with NUL on -z');
is_deeply(opustags(qw(out.opus)), [<<'END', '', 0], 'indents continuation lines');
MULTILINE=one
	two
SIMPLE=three
END
unlink('out.opus');
