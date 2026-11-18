#include <opustags.h>
#include "tap.h"

#include <string.h>

static const char standard_OpusTags[] =
	"OpusTags"
	"\x14\x00\x00\x00" "opustags test packet"
	"\x02\x00\x00\x00"
	"\x09\x00\x00\x00" "TITLE=Foo"
	"\x0a\x00\x00\x00" "ARTIST=Bar";

static void parse_standard()
{
	ogg_packet op;
	op.bytes = sizeof(standard_OpusTags) - 1;
	op.packet = (unsigned char*) standard_OpusTags;
	ot::opus_tags tags = ot::parse_tags(op);
	if (tags.vendor != u8"opustags test packet")
		throw failure("bad vendor string");
	if (tags.comments.size() != 2)
		throw failure("bad number of comments");
	auto it = tags.comments.begin();
	if (*it != u8"TITLE=Foo")
		throw failure("bad title");
	++it;
	if (*it != u8"ARTIST=Bar")
		throw failure("bad artist");
	if (tags.extra_data.size() != 0)
		throw failure("found mysterious padding data");
}

static ot::status try_parse_tags(const ogg_packet& packet)
{
	try {
		ot::parse_tags(packet);
		return ot::st::ok;
	} catch (const ot::status& rc) {
		return rc;
	}
}

/**
 * Try parse_tags with packets that should not valid, or that might even
 * corrupt the memory. Run this one with valgrind to ensure we're not
 * overflowing.
 */
static void parse_corrupted()
{
	size_t size = sizeof(standard_OpusTags);
	char packet[size];
	memcpy(packet, standard_OpusTags, size);
	ot::opus_tags tags;
	ogg_packet op;
	op.packet = (unsigned char*) packet;
	op.bytes = size;

	char* header_data = packet;
	char* vendor_length = header_data + 8;
	char* vendor_string = vendor_length + 4;
	char* comment_count = vendor_string + *vendor_length;
	char* first_comment_length = comment_count + 4;
	char* first_comment_data = first_comment_length + 4;
	char* end = packet + size;

	op.bytes = 7;
	if (try_parse_tags(op) != ot::st::cut_magic_number)
		throw failure("did not detect the overflowing magic number");
	op.bytes = 11;
	if (try_parse_tags(op) != ot::st::cut_vendor_length)
		throw failure("did not detect the overflowing vendor string length");
	op.bytes = size;

	header_data[0] = 'o';
	if (try_parse_tags(op) != ot::st::bad_magic_number)
		throw failure("did not detect the bad magic number");
	header_data[0] = 'O';

	*vendor_length = end - vendor_string + 1;
	if (try_parse_tags(op) != ot::st::cut_vendor_data)
		throw failure("did not detect the overflowing vendor string");
	*vendor_length = end - vendor_string - 3;
	if (try_parse_tags(op) != ot::st::cut_comment_count)
		throw failure("did not detect the overflowing comment count");
	*vendor_length = comment_count - vendor_string;

	++*comment_count;
	if (try_parse_tags(op) != ot::st::cut_comment_length)
		throw failure("did not detect the overflowing comment length");
	*first_comment_length = end - first_comment_data + 1;
	if (try_parse_tags(op) != ot::st::cut_comment_data)
		throw failure("did not detect the overflowing comment data");
}

static void recode_standard()
{
	ogg_packet op;
	op.bytes = sizeof(standard_OpusTags) - 1;
	op.packet = (unsigned char*) standard_OpusTags;
	ot::opus_tags tags = ot::parse_tags(op);
	auto packet = ot::render_tags(tags);
	if (packet.b_o_s != 0)
		throw failure("b_o_s should not be set");
	if (packet.e_o_s != 0)
		throw failure("e_o_s should not be set");
	if (packet.granulepos != 0)
		throw failure("granule_post should be 0");
	if (packet.packetno != 1)
		throw failure("packetno should be 1");
	if (packet.bytes != sizeof(standard_OpusTags) - 1)
		throw failure("the packet is not the right size");
	if (memcmp(packet.packet, standard_OpusTags, packet.bytes) != 0)
		throw failure("the rendered packet is not what we expected");
}

static void recode_padding()
{
	std::string padded_OpusTags(standard_OpusTags, sizeof(standard_OpusTags));
	// ^ note: padded_OpusTags ends with a null byte here
	padded_OpusTags += "hello";
	ogg_packet op;
	op.bytes = padded_OpusTags.size();
	op.packet = (unsigned char*) padded_OpusTags.data();

	ot::opus_tags tags = ot::parse_tags(op);
	if (tags.extra_data != "\0hello"sv)
		throw failure("corrupted extra data");
	// recode the packet and ensure it's exactly the same
	auto packet = ot::render_tags(tags);
	if (static_cast<size_t>(packet.bytes) < padded_OpusTags.size())
		throw failure("the packet was truncated");
	if (static_cast<size_t>(packet.bytes) > padded_OpusTags.size())
		throw failure("the packet got too big");
	if (memcmp(packet.packet, padded_OpusTags.data(), packet.bytes) != 0)
		throw failure("the rendered packet is not what we expected");
}

static void extract_cover()
{
	ot::byte_string_view picture_data = ""sv
		"\x00\x00\x00\x03" // Picture type 3.
		"\x00\x00\x00\x09" "image/foo" // MIME type.
		"\x00\x00\x00\x00" "" // Description.
		"\x00\x00\x00\x00" // Width.
		"\x00\x00\x00\x00" // Height.
		"\x00\x00\x00\x00" // Color depth.
		"\x00\x00\x00\x00" // Palette size.
		"\x00\x00\x00\x0C" "Picture data";

	ot::opus_tags tags;
	tags.comments = { u8"METADATA_BLOCK_PICTURE=" + ot::encode_base64(picture_data) };
	std::optional<ot::picture> cover = ot::extract_cover(tags);
	if (!cover)
		throw failure("could not extract the cover");
	if (cover->mime_type != "image/foo"sv)
		throw failure("bad extracted MIME type");
	if (cover->picture_data != "Picture data"sv)
		throw failure("bad extracted picture data");

	ot::byte_string_view truncated_data = picture_data.substr(0, picture_data.size() - 1);
	tags.comments = { u8"METADATA_BLOCK_PICTURE=" + ot::encode_base64(truncated_data) };
	try {
		ot::extract_cover(tags);
		throw failure("accepted a bad picture block");
	} catch (const ot::status& rc) {}
}

static void make_cover()
{
	ot::byte_string_view picture_block = ""sv
		"\x00\x00\x00\x03" // Picture type 3.
		"\x00\x00\x00\x09" "image/png" // MIME type.
		"\x00\x00\x00\x00" "" // Description.
		"\x00\x00\x00\x00" // Width.
		"\x00\x00\x00\x00" // Height.
		"\x00\x00\x00\x00" // Color depth.
		"\x00\x00\x00\x00" // Palette size.
		"\x00\x00\x00\x11" "\x89PNG Picture data";

	std::u8string expected = u8"METADATA_BLOCK_PICTURE=" + ot::encode_base64(picture_block);
	opaque_is(ot::make_cover("\x89PNG Picture data"sv), expected, "build the picture tag");
}

/**
 * Check the packet size <-> page count arithmetic, in particular the lacing boundary where a
 * packet of exactly 255*255 bytes spills onto an extra zero-lacing page.
 */
static void page_count_math()
{
	if (ot::packet_page_count(0) != 1)
		throw failure("an empty packet still takes one page");
	if (ot::packet_page_count(62) != 1)
		throw failure("a small packet takes a single page");
	if (ot::packet_page_count(65024) != 1)
		throw failure("65024 bytes should fit on a single page");
	if (ot::packet_page_count(65025) != 2)
		throw failure("65025 bytes spill on a second zero-lacing page");
	if (ot::packet_page_count(65026) != 2)
		throw failure("65026 bytes take two pages");
	if (ot::packet_page_count(130050) != 3)
		throw failure("130050 bytes take three pages");

	// max_packet_size must be the exact inverse of packet_page_count.
	for (int pages = 1; pages <= 3; ++pages) {
		size_t max_size = ot::max_packet_size(pages);
		if (ot::packet_page_count(max_size) != pages)
			throw failure("max_packet_size does not fit in the requested page count");
		if (ot::packet_page_count(max_size + 1) != pages + 1)
			throw failure("max_packet_size + 1 must spill onto another page");
	}
}

static void padding_preserves_size()
{
	// A packet that shrank must be padded back to its exact original size, with plain zero bytes
	// appended to the extra data.
	ot::opus_tags tags;
	tags.vendor = u8"v";
	tags.comments = {u8"A=1"};
	size_t original_size = 5000;
	ot::pad_tags_packet(tags, original_size);
	auto packet = ot::render_tags(tags);
	if (static_cast<size_t>(packet.bytes) != original_size)
		throw failure("shrunk packet was not padded back to its original size");
	if (ot::packet_page_count(packet.bytes) != ot::packet_page_count(original_size))
		throw failure("padding changed the pagination");
}

static void padding_allows_growth_within_pages()
{
	// Growing while staying inside the original page span is allowed and needs no padding: the
	// page count is unchanged, and the following pages keep their boundaries and sequence
	// numbers.
	ot::opus_tags tags;
	tags.vendor = u8"v";
	tags.comments = {u8"A=" + std::u8string(100, u8'x')};
	size_t original_size = 62; // the original, smaller single-page packet
	size_t before = ot::render_tags(tags).bytes;
	ot::pad_tags_packet(tags, original_size);
	if (ot::render_tags(tags).bytes != before)
		throw failure("a grown packet that still fits must not be padded");
	if (ot::packet_page_count(ot::render_tags(tags).bytes) != 1)
		throw failure("the grown packet must stay on a single page");
}

static void padding_rejects_overflow()
{
	// A packet that would need more pages than the original must be rejected rather than disturb
	// the pagination of the rest of the stream.
	ot::opus_tags tags;
	tags.vendor = u8"v";
	tags.comments = {u8"A=" + std::u8string(65024, u8'x')};
	try {
		ot::pad_tags_packet(tags, 62); // original packet fit on a single page
		throw failure("an overflowing packet was not rejected");
	} catch (const ot::status& rc) {
		if (rc != ot::st::error)
			throw failure("unexpected status code for an overflowing packet");
	}
}

int main()
{
	std::cout << "1..10\n";
	run(parse_standard, "parse a standard OpusTags packet");
	run(parse_corrupted, "correctly reject invalid packets");
	run(recode_standard, "recode a standard OpusTags packet");
	run(recode_padding, "recode a OpusTags packet with padding");
	run(extract_cover, "extract the cover art");
	run(make_cover, "encode the cover art");
	run(page_count_math, "packet size to page count arithmetic");
	run(padding_preserves_size, "pad a shrunk packet to its original size");
	run(padding_allows_growth_within_pages, "allow growth within the original pages");
	run(padding_rejects_overflow, "reject tags overflowing the original pages");
	return 0;
}
