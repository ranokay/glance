use super::{
    MAX_ENTRY_COUNT, MAX_HEADER_SIZE, SIGNATURE, SIGNATURE_HEADER_SIZE, crc32, read_u32, read_u64,
};
use crate::error::CoreError;
use sevenz_rust2::{Archive, BlockDecoder, EncoderMethod, Password};
use std::fs::File;
use std::io::{Cursor, Read, Seek, SeekFrom};

const MAX_CODERS: usize = 16;
const MAX_STREAMS: usize = MAX_CODERS * 4;
const MAX_DECODER_MEMORY: u64 = 128 * 1_024 * 1_024;

pub(super) fn read_archive(file: &mut File, file_size: u64) -> Result<Archive, CoreError> {
    let serialized = read_serialized_header(file, file_size)?;
    let header = if serialized.first() == Some(&0x17) {
        decode_header(file, file_size, &serialized)?
    } else {
        serialized
    };
    validate_header(&header)?;
    parse_snapshot(&header)
}

fn read_serialized_header(file: &mut File, file_size: u64) -> Result<Vec<u8>, CoreError> {
    if file_size < SIGNATURE_HEADER_SIZE {
        return Err(CoreError::parse("7z signature header is truncated"));
    }
    file.seek(SeekFrom::Start(0)).map_err(io_error)?;
    let mut signature = [0; SIGNATURE_HEADER_SIZE as usize];
    file.read_exact(&mut signature).map_err(io_error)?;
    if &signature[..6] != SIGNATURE {
        return Err(CoreError::parse("7z archive has an invalid signature"));
    }
    if signature[6] != 0 {
        return Err(CoreError::unsupported("Unsupported 7z major version"));
    }
    if crc32(&signature[12..]) != read_u32(&signature, 8).unwrap() {
        return Err(CoreError::parse(
            "7z signature header checksum does not match",
        ));
    }
    let offset = read_u64(&signature, 12).unwrap();
    let size = read_u64(&signature, 20).unwrap();
    if size > MAX_HEADER_SIZE {
        return Err(CoreError::limit(
            "7z serialized metadata exceeds the preview limit",
        ));
    }
    let start = SIGNATURE_HEADER_SIZE
        .checked_add(offset)
        .ok_or_else(|| CoreError::limit("7z metadata offset overflow"))?;
    let end = start
        .checked_add(size)
        .ok_or_else(|| CoreError::limit("7z metadata size overflow"))?;
    if end > file_size {
        return Err(CoreError::parse(
            "7z metadata header lies outside the archive",
        ));
    }
    file.seek(SeekFrom::Start(start)).map_err(io_error)?;
    let mut header = vec![0; size as usize];
    file.read_exact(&mut header).map_err(io_error)?;
    if crc32(&header) != read_u32(&signature, 28).unwrap() {
        return Err(CoreError::parse(
            "7z metadata header checksum does not match",
        ));
    }
    Ok(header)
}

fn parse_snapshot(header: &[u8]) -> Result<Archive, CoreError> {
    // The dependency parses this immutable plain header, never re-reading unchecked
    // file metadata or invoking its unbounded encoded-header path.
    let mut start = Vec::with_capacity(20);
    start.extend(0_u64.to_le_bytes());
    start.extend((header.len() as u64).to_le_bytes());
    start.extend(crc32(header).to_le_bytes());
    let mut snapshot = Vec::with_capacity(SIGNATURE_HEADER_SIZE as usize + header.len());
    snapshot.extend(SIGNATURE);
    snapshot.extend([0, 4]);
    snapshot.extend(crc32(&start).to_le_bytes());
    snapshot.extend(start);
    snapshot.extend(header);
    Archive::read(&mut Cursor::new(snapshot), &Password::empty())
        .map_err(super::map_seven_zip_error)
}

fn decode_header(file: &mut File, file_size: u64, serialized: &[u8]) -> Result<Vec<u8>, CoreError> {
    let mut cursor = HeaderCursor::new(serialized);
    cursor.expect(0x17)?;
    let streams = cursor.streams(true)?;
    if cursor.position != serialized.len() || streams.blocks.is_empty() {
        return Err(CoreError::parse("Invalid encoded 7z header streams"));
    }
    // Reuse the pinned decoder through its bounded file-stream API. Each block is
    // represented as one synthetic file; the encoded-header format uses the first.
    let mut synthetic = vec![0x01, 0x04];
    synthetic.extend(&serialized[1..streams.unpack_end]);
    synthetic.extend([0x08, 0x0a, 0]);
    let missing_crcs = streams.blocks.iter().filter(|block| !block.has_crc).count();
    synthetic.resize(synthetic.len() + missing_crcs.div_ceil(8), 0);
    synthetic.extend([0, 0, 0x05]);
    write_number(&mut synthetic, streams.blocks.len() as u64);
    synthetic.extend([0, 0]);
    let archive = parse_snapshot(&synthetic)?;
    let packed_end = archive.pack_sizes().iter().try_fold(
        SIGNATURE_HEADER_SIZE
            .checked_add(archive.pack_pos())
            .ok_or_else(|| CoreError::limit("7z packed header offset overflow"))?,
        |position, size| {
            position
                .checked_add(*size)
                .ok_or_else(|| CoreError::limit("7z packed header size overflow"))
        },
    )?;
    if packed_end > file_size {
        return Err(CoreError::parse(
            "7z packed header lies outside the archive",
        ));
    }
    validate_decoder_budget(&archive, 0, Some(MAX_HEADER_SIZE))?;
    let expected = archive.blocks[0].get_unpack_size();
    let mut header = Vec::new();
    BlockDecoder::new(1, 0, &archive, &Password::empty(), file)
        .for_each_entries(&mut |_, reader| {
            reader.take(MAX_HEADER_SIZE + 1).read_to_end(&mut header)?;
            Ok(false)
        })
        .map_err(super::map_seven_zip_error)?;
    if header.len() as u64 > MAX_HEADER_SIZE {
        return Err(CoreError::limit(
            "7z decoded metadata exceeds the preview limit",
        ));
    }
    if header.len() as u64 != expected {
        return Err(CoreError::parse("7z decoded metadata is truncated"));
    }
    Ok(header)
}

pub(super) fn validate_decoder_budget(
    archive: &Archive,
    block_index: usize,
    output_limit: Option<u64>,
) -> Result<(), CoreError> {
    let block = &archive.blocks[block_index];
    let mut memory = 0_u64;
    for (index, coder) in block.coders.iter().enumerate() {
        let output = block.get_unpack_size_at_index(index);
        if output_limit.is_some_and(|limit| output > limit) {
            return Err(CoreError::limit(
                "7z decoded metadata exceeds the preview limit",
            ));
        }
        let properties = coder.properties();
        let required = match coder.encoder_method_id() {
            EncoderMethod::ID_LZMA => {
                if properties.len() < 5 || properties[0] >= 9 * 5 * 5 {
                    return Err(CoreError::parse("Invalid 7z LZMA properties"));
                }
                let dictionary = u32::from_le_bytes(properties[1..5].try_into().unwrap()) as u64;
                let lc = u32::from(properties[0] % 9);
                let lp = u32::from((properties[0] / 9) % 5);
                let history = if output <= u64::MAX / 2 {
                    dictionary.min(output)
                } else {
                    dictionary
                };
                history.max(4096).next_multiple_of(16) + (0x300_u64 << (lc + lp)) * 2 + 128 * 1_024
            }
            EncoderMethod::ID_LZMA2 => {
                let bits = *properties
                    .first()
                    .ok_or_else(|| CoreError::parse("Missing LZMA2 properties"))?;
                let dictionary = match bits {
                    0..=39 => (2_u64 | u64::from(bits & 1)) << (u32::from(bits / 2) + 11),
                    40 => u64::from(u32::MAX),
                    _ => return Err(CoreError::parse("Invalid LZMA2 properties")),
                };
                // Unlike LZMA, LZMA2 does not clamp its dictionary to the known
                // output size. Its lazy history buffer doubles as it grows.
                dictionary.min(output.saturating_mul(2).max(64 * 1_024)) + 6 * 1_024 * 1_024
            }
            EncoderMethod::ID_PPMD => {
                if properties.len() < 5 {
                    return Err(CoreError::parse("Invalid PPMd properties"));
                }
                u64::from(u32::from_le_bytes(properties[1..5].try_into().unwrap())) + 64 * 1_024
            }
            EncoderMethod::ID_BZIP2 => 9 * 1_024 * 1_024,
            // The pinned BCJ2 decoder streams through four 256 KiB buffers.
            EncoderMethod::ID_BCJ2 => 1_024 * 1_024 + 64 * 1_024,
            EncoderMethod::ID_AES256_SHA256 => {
                return Err(CoreError::unsupported(
                    "Encrypted 7z archives are not supported",
                ));
            }
            _ => 64 * 1_024,
        };
        memory = memory
            .checked_add(required)
            .ok_or_else(|| CoreError::limit("7z decoder memory size overflow"))?;
    }
    if memory > MAX_DECODER_MEMORY {
        return Err(CoreError::limit(
            "7z decoder exceeds the 128 MiB memory preview limit",
        ));
    }
    Ok(())
}

fn validate_header(header: &[u8]) -> Result<(), CoreError> {
    let mut cursor = HeaderCursor::new(header);
    cursor.expect(0x01)?;
    let mut tag = cursor.byte()?;
    if tag == 0x02 {
        loop {
            if cursor.byte()? == 0 {
                break;
            }
            let size = cursor.count(header.len(), "archive property bytes")?;
            cursor.take(size)?;
        }
        tag = cursor.byte()?;
    }
    if tag == 0x03 {
        return Err(CoreError::unsupported(
            "Additional 7z streams are not supported",
        ));
    }
    if tag == 0x04 {
        cursor.streams(false)?;
        tag = cursor.byte()?;
    }
    if tag == 0x05 {
        // The dependency allocates file records here. Stop before that allocation;
        // it remains responsible for parsing FilesInfo properties and their lengths.
        cursor.count(MAX_ENTRY_COUNT, "file count")?;
    } else if tag != 0 {
        return Err(CoreError::parse("Invalid 7z metadata header"));
    }
    Ok(())
}

struct BlockShape {
    outputs: usize,
    final_output: usize,
    unpack_size: u64,
    has_crc: bool,
}

struct Streams {
    blocks: Vec<BlockShape>,
    unpack_end: usize,
}

struct HeaderCursor<'a> {
    bytes: &'a [u8],
    position: usize,
    coders: usize,
}

impl<'a> HeaderCursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            bytes,
            position: 0,
            coders: 0,
        }
    }

    fn take(&mut self, count: usize) -> Result<&'a [u8], CoreError> {
        let end = self
            .position
            .checked_add(count)
            .ok_or_else(|| CoreError::parse("7z metadata offset overflow"))?;
        let value = self
            .bytes
            .get(self.position..end)
            .ok_or_else(|| CoreError::parse("Truncated 7z metadata"))?;
        self.position = end;
        Ok(value)
    }

    fn byte(&mut self) -> Result<u8, CoreError> {
        Ok(self.take(1)?[0])
    }

    fn expect(&mut self, expected: u8) -> Result<(), CoreError> {
        if self.byte()? != expected {
            return Err(CoreError::parse("Invalid 7z metadata field"));
        }
        Ok(())
    }

    fn number(&mut self) -> Result<u64, CoreError> {
        let first = self.byte()?;
        let mut mask = 0x80_u8;
        let mut value = 0_u64;
        for shift in 0..8 {
            if first & mask == 0 {
                return Ok(value | (u64::from(first & (mask - 1)) << (shift * 8)));
            }
            value |= u64::from(self.byte()?) << (shift * 8);
            mask >>= 1;
        }
        Ok(value)
    }

    fn count(&mut self, limit: usize, field: &str) -> Result<usize, CoreError> {
        let value = self.number()?;
        if value > limit as u64 {
            return Err(CoreError::limit(format!(
                "7z {field} exceeds the preview limit"
            )));
        }
        if value > self.bytes.len() as u64 {
            return Err(CoreError::parse(format!(
                "7z {field} exceeds available metadata"
            )));
        }
        Ok(value as usize)
    }

    fn crcs(&mut self, count: usize) -> Result<Vec<bool>, CoreError> {
        let present = if self.byte()? != 0 {
            vec![true; count]
        } else {
            let bits = self.take(count.div_ceil(8))?;
            (0..count)
                .map(|index| bits[index / 8] & (0x80 >> (index % 8)) != 0)
                .collect()
        };
        self.take(present.iter().filter(|value| **value).count() * 4)?;
        Ok(present)
    }

    fn block(&mut self, encoded: bool) -> Result<BlockShape, CoreError> {
        let count = self.count(MAX_CODERS, "coders per block")?;
        self.coders += count;
        if self.coders > MAX_ENTRY_COUNT * 4 {
            return Err(CoreError::limit("7z coder count exceeds the preview limit"));
        }
        let mut inputs = 0_usize;
        let mut outputs = 0_usize;
        let mut input_owners = Vec::new();
        let mut output_owners = Vec::new();
        for coder_index in 0..count {
            let flags = self.byte()?;
            self.take(usize::from(flags & 0x0f))?;
            let (input, output) = if flags & 0x10 == 0 {
                (1, 1)
            } else {
                (
                    self.count(MAX_STREAMS, "coder inputs")?,
                    self.count(MAX_STREAMS, "coder outputs")?,
                )
            };
            if encoded && (input != 1 || output != 1) {
                return Err(CoreError::unsupported(
                    "Multi-stream encoded 7z headers are not supported",
                ));
            }
            inputs += input;
            outputs += output;
            if inputs > MAX_STREAMS || outputs > MAX_STREAMS {
                return Err(CoreError::limit(
                    "7z coder streams exceed the preview limit",
                ));
            }
            input_owners.extend(std::iter::repeat_n(coder_index, input));
            output_owners.extend(std::iter::repeat_n(coder_index, output));
            if flags & 0x20 != 0 {
                let size = self.count(self.bytes.len(), "coder property bytes")?;
                self.take(size)?;
            }
            if flags & 0x80 != 0 {
                return Err(CoreError::unsupported(
                    "Alternative 7z coder methods are not supported",
                ));
            }
        }
        if outputs == 0 || inputs < outputs - 1 {
            return Err(CoreError::parse("Invalid 7z coder stream counts"));
        }
        let mut bound_inputs = vec![false; inputs];
        let mut bound_outputs = vec![false; outputs];
        let mut dependents = vec![Vec::new(); count];
        let mut dependencies = vec![0_usize; count];
        for _ in 0..outputs - 1 {
            let input = self.number()?;
            let output = self.number()?;
            if input >= inputs as u64
                || output >= outputs as u64
                || bound_inputs[input as usize]
                || bound_outputs[output as usize]
            {
                return Err(CoreError::parse("Invalid 7z coder binding"));
            }
            bound_inputs[input as usize] = true;
            bound_outputs[output as usize] = true;
            let consumer = input_owners[input as usize];
            let producer = output_owners[output as usize];
            dependents[producer].push(consumer);
            dependencies[consumer] += 1;
        }
        let mut ready: Vec<_> = (0..count)
            .filter(|index| dependencies[*index] == 0)
            .collect();
        let mut visited = 0;
        while let Some(index) = ready.pop() {
            visited += 1;
            for dependent in &dependents[index] {
                dependencies[*dependent] -= 1;
                if dependencies[*dependent] == 0 {
                    ready.push(*dependent);
                }
            }
        }
        if visited != count {
            return Err(CoreError::parse("Cyclic 7z coder bindings"));
        }
        let packed = inputs - (outputs - 1);
        if packed != 1 {
            for _ in 0..packed {
                let input = self.number()?;
                if input >= inputs as u64 || bound_inputs[input as usize] {
                    return Err(CoreError::parse("Invalid 7z packed stream"));
                }
                bound_inputs[input as usize] = true;
            }
        }
        let final_output = bound_outputs.iter().rposition(|bound| !bound).unwrap_or(0);
        Ok(BlockShape {
            outputs,
            final_output,
            unpack_size: 0,
            has_crc: false,
        })
    }

    fn streams(&mut self, encoded: bool) -> Result<Streams, CoreError> {
        let mut tag = self.byte()?;
        if tag == 0x06 {
            self.number()?;
            let count = self.count(MAX_ENTRY_COUNT, "packed stream count")?;
            tag = self.byte()?;
            if tag == 0x09 {
                for _ in 0..count {
                    self.number()?;
                }
                tag = self.byte()?;
            }
            if tag == 0x0a {
                self.crcs(count)?;
                tag = self.byte()?;
            }
            if tag != 0 {
                return Err(CoreError::parse("Invalid 7z packed streams"));
            }
            tag = self.byte()?;
        }
        let mut blocks = Vec::new();
        if tag == 0x07 {
            self.expect(0x0b)?;
            let count = self.count(MAX_ENTRY_COUNT, "compression block count")?;
            if self.byte()? != 0 {
                return Err(CoreError::unsupported(
                    "External 7z folders are not supported",
                ));
            }
            for _ in 0..count {
                blocks.push(self.block(encoded)?);
            }
            self.expect(0x0c)?;
            for block in &mut blocks {
                for index in 0..block.outputs {
                    let size = self.number()?;
                    if encoded && size > MAX_HEADER_SIZE {
                        return Err(CoreError::limit(
                            "7z decoded metadata exceeds the preview limit",
                        ));
                    }
                    if index == block.final_output {
                        block.unpack_size = size;
                    }
                }
            }
            tag = self.byte()?;
            if tag == 0x0a {
                for (block, has_crc) in blocks.iter_mut().zip(self.crcs(count)?) {
                    block.has_crc = has_crc;
                }
                tag = self.byte()?;
            }
            if tag != 0 {
                return Err(CoreError::parse("Invalid 7z unpacked streams"));
            }
            tag = self.byte()?;
        }
        let unpack_end = self.position - 1;
        if tag == 0x08 {
            let mut counts = vec![1_usize; blocks.len()];
            tag = self.byte()?;
            if tag == 0x0d {
                let mut total = 0_usize;
                for count in &mut counts {
                    *count = self.count(MAX_ENTRY_COUNT, "substream count")?;
                    total += *count;
                    if total > MAX_ENTRY_COUNT {
                        return Err(CoreError::limit(
                            "7z substream count exceeds the preview limit",
                        ));
                    }
                }
                tag = self.byte()?;
            }
            if tag == 0x09 {
                for (block, count) in blocks.iter().zip(&counts) {
                    let mut total = 0_u64;
                    for _ in 0..count.saturating_sub(1) {
                        total = total
                            .checked_add(self.number()?)
                            .ok_or_else(|| CoreError::parse("7z substream size overflow"))?;
                    }
                    if total > block.unpack_size {
                        return Err(CoreError::parse("Invalid 7z substream sizes"));
                    }
                }
                tag = self.byte()?;
            }
            if tag == 0x0a {
                let digests = blocks
                    .iter()
                    .zip(&counts)
                    .filter(|(block, count)| **count != 1 || !block.has_crc)
                    .map(|(_, count)| *count)
                    .sum();
                self.crcs(digests)?;
                tag = self.byte()?;
            }
            if tag != 0 {
                return Err(CoreError::parse("Invalid 7z substreams"));
            }
            tag = self.byte()?;
        }
        if tag != 0 {
            return Err(CoreError::parse("Invalid 7z streams terminator"));
        }
        Ok(Streams { blocks, unpack_end })
    }
}

fn write_number(output: &mut Vec<u8>, value: u64) {
    if value < 0x80 {
        output.push(value as u8);
    } else {
        output.push(0xff);
        output.extend(value.to_le_bytes());
    }
}

fn io_error(error: std::io::Error) -> CoreError {
    CoreError::io(format!("Could not read 7z metadata: {error}"))
}

#[cfg(test)]
mod tests {
    use super::super::tests::{archive_with_header, solid_copy_archive, temporary_path};
    use super::super::{extract_entry, scan_seven_zip};
    use super::*;

    fn descriptor(
        method: &[u8],
        properties: &[u8],
        output: u64,
        packed: u64,
        count: usize,
    ) -> Vec<u8> {
        let mut bytes = vec![0x17, 0x06, 0, 1, 0x09];
        write_number(&mut bytes, packed);
        bytes.extend([0, 0x07, 0x0b, 1, 0]);
        write_number(&mut bytes, count as u64);
        for _ in 0..count {
            bytes.push(method.len() as u8 | if properties.is_empty() { 0 } else { 0x20 });
            bytes.extend(method);
            if !properties.is_empty() {
                write_number(&mut bytes, properties.len() as u64);
                bytes.extend(properties);
            }
        }
        for index in 0..count.saturating_sub(1) {
            write_number(&mut bytes, (index + 1) as u64);
            write_number(&mut bytes, index as u64);
        }
        bytes.push(0x0c);
        for _ in 0..count {
            write_number(&mut bytes, output);
        }
        bytes.extend([0, 0x08, 0, 0]);
        bytes
    }

    fn assert_limit_on_both_routes(content: &[u8], header: &[u8]) {
        let path = temporary_path();
        std::fs::write(&path, archive_with_header(content, header)).unwrap();
        let scanned = scan_seven_zip(&path);
        let extracted = extract_entry(&path, "missing.txt", 1_024);
        std::fs::remove_file(path).unwrap();
        assert!(
            matches!(scanned, Err(CoreError::ResourceLimit(_))),
            "{scanned:?}"
        );
        assert!(
            matches!(extracted, Err(CoreError::ResourceLimit(_))),
            "{extracted:?}"
        );
    }

    #[test]
    fn rejects_ppmd_memory_request_before_constructing_a_decoder() {
        let mut properties = vec![6];
        properties.extend(((MAX_DECODER_MEMORY + 1) as u32).to_le_bytes());
        assert_limit_on_both_routes(
            &[],
            &descriptor(EncoderMethod::ID_PPMD, &properties, 2, 0, 1),
        );
    }

    #[test]
    fn bounds_the_combined_memory_of_live_header_coders() {
        let mut properties = vec![6];
        properties.extend((48_u32 * 1_024 * 1_024).to_le_bytes());
        assert_limit_on_both_routes(
            &[],
            &descriptor(EncoderMethod::ID_PPMD, &properties, 2, 0, 3),
        );
    }

    #[test]
    fn includes_lzma2_history_growth_in_the_extraction_budget() {
        let mut header = descriptor(EncoderMethod::ID_LZMA2, &[40], 65 * 1_024 * 1_024, 0, 1);
        // Reuse the descriptor's StreamsInfo as ordinary payload metadata.
        header.splice(..1, [0x01, 0x04]);
        header.extend([0x05, 1, 0, 0]);
        validate_header(&header).unwrap();
        let archive = parse_snapshot(&header).unwrap();
        assert!(matches!(
            validate_decoder_budget(&archive, 0, None),
            Err(CoreError::ResourceLimit(_))
        ));
    }

    #[test]
    fn bounds_encoded_header_coder_count_before_dependency_allocation() {
        assert_limit_on_both_routes(
            &[],
            &descriptor(EncoderMethod::ID_COPY, &[], 2, 0, MAX_CODERS + 1),
        );
    }

    #[test]
    fn checks_decoded_file_counts_before_parsing_them() {
        let mut plain = vec![0x01, 0x05];
        write_number(&mut plain, MAX_ENTRY_COUNT as u64 + 1);
        plain.resize(MAX_ENTRY_COUNT + 32, 0);
        let header = descriptor(
            EncoderMethod::ID_COPY,
            &[],
            plain.len() as u64,
            plain.len() as u64,
            1,
        );
        assert_limit_on_both_routes(&plain, &header);
    }

    #[test]
    fn preserves_long_variable_integer_encodings_and_copy_headers() {
        let plain = [0x01, 0x05, 0, 0, 0];
        let mut header = descriptor(
            EncoderMethod::ID_COPY,
            &[],
            plain.len() as u64,
            plain.len() as u64,
            1,
        );
        // The packed-stream count one has an equivalent nine-byte form.
        header.splice(3..4, [vec![0xff], 1_u64.to_le_bytes().to_vec()].concat());
        let path = temporary_path();
        std::fs::write(&path, archive_with_header(&plain, &header)).unwrap();
        let result = scan_seven_zip(&path);
        std::fs::remove_file(path).unwrap();
        assert!(result.unwrap().entries.is_empty());
    }

    #[test]
    fn metadata_snapshot_does_not_re_read_changed_source_bytes() {
        let path = temporary_path();
        std::fs::write(&path, solid_copy_archive()).unwrap();
        let mut file = File::open(&path).unwrap();
        let file_size = file.metadata().unwrap().len();
        let snapshot = read_serialized_header(&mut file, file_size).unwrap();
        std::fs::write(&path, b"replaced after validation").unwrap();
        validate_header(&snapshot).unwrap();
        let archive = parse_snapshot(&snapshot).unwrap();
        std::fs::remove_file(path).unwrap();
        assert_eq!(archive.files[0].name, "first.txt");
        assert_eq!(archive.files[1].name, "second.txt");
    }

    #[test]
    fn malformed_and_nested_encoded_metadata_fail_without_panicking() {
        for body in [
            vec![],
            vec![0x17],
            vec![0x01, 0x03],
            vec![0x01, 0x04, 0x07],
            vec![0x01, 0x05, 0xff],
        ] {
            assert!(validate_header(&body).is_err());
        }
    }

    #[test]
    fn rejects_aliased_coder_bindings_before_building_decoders() {
        // A decoder can otherwise follow a repeated binding and instantiate the
        // same memory-heavy coder more than once, defeating a per-coder budget.
        for bindings in [[0, 1, 0, 0], [1, 0, 2, 0], [0, 1, 1, 0]] {
            let mut block = vec![3, 1, 0, 1, 0, 1, 0];
            block.extend(bindings);
            assert!(HeaderCursor::new(&block).block(false).is_err());
            assert!(HeaderCursor::new(&block).block(true).is_err());

            let mut header = vec![1, 4, 6, 0, 1, 9, 0, 0, 7, 0x0b, 1, 0];
            header.extend(block);
            header.extend([0x0c, 0, 0, 0, 0, 0, 5, 0, 0, 0]);
            let path = temporary_path();
            std::fs::write(&path, archive_with_header(&[], &header)).unwrap();
            assert!(matches!(scan_seven_zip(&path), Err(CoreError::Parse(_))));
            assert!(matches!(
                extract_entry(&path, "", 1_024),
                Err(CoreError::Parse(_))
            ));
            std::fs::remove_file(path).unwrap();
        }
    }

    #[test]
    fn streams_a_small_entry_from_a_large_bcj2_solid_block() {
        use std::io::Write;

        let size = 70 * 1_024 * 1_024;
        let mut header = vec![1, 4, 6, 0, 4, 9];
        for packed_size in [size, 0, 0, 5] {
            write_number(&mut header, packed_size);
        }
        header.extend([0, 7, 0x0b, 1, 0, 1, 0x14]);
        header.extend(EncoderMethod::ID_BCJ2);
        header.extend([4, 1, 0, 1, 2, 3, 0x0c]);
        write_number(&mut header, size);
        header.extend([0, 8, 0x0d, 2, 9]);
        write_number(&mut header, 1_024);
        header.extend([0, 0, 5, 2, 0x11]);
        let names: Vec<_> = "first.txt\0second.txt\0"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        write_number(&mut header, names.len() as u64 + 1);
        header.push(0);
        header.extend(names);
        header.extend([0, 0]);

        // Sparse zero-filled MAIN data avoids a 70 MiB test allocation while
        // exercising the real BCJ2 reader and the selected solid-entry route.
        let path = temporary_path();
        let mut file = File::create(&path).unwrap();
        let mut signature = archive_with_header(&[], &header)[..32].to_vec();
        signature[12..20].copy_from_slice(&(size + 5).to_le_bytes());
        let checksum = crc32(&signature[12..]);
        signature[8..12].copy_from_slice(&checksum.to_le_bytes());
        file.write_all(&signature).unwrap();
        file.seek(SeekFrom::Start(32 + size)).unwrap();
        file.write_all(&[0; 5]).unwrap();
        file.write_all(&header).unwrap();
        drop(file);
        let scanned = scan_seven_zip(&path);
        let extracted = extract_entry(&path, "first.txt", 1_024);
        std::fs::remove_file(path).unwrap();
        assert_eq!(scanned.unwrap().entries.len(), 2);
        assert_eq!(extracted.unwrap(), vec![0; 1_024]);
    }
}
