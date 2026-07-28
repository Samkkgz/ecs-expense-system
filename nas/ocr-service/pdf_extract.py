#!/usr/bin/env python3
"""Extract invoice images from Chinese electronic invoice PDFs using stdlib only"""
import re, zlib, struct, os, sys

def extract_images_from_pdf(pdf_path):
    """Find and extract JPEG/PNG images from PDF streams"""
    with open(pdf_path, 'rb') as f:
        data = f.read()
    
    results = []
    
    # Method 1: Search for raw JPEG/PNG headers in decompressed streams
    for m in re.finditer(rb'stream\s(.+?)\nendstream', data, re.DOTALL):
        raw = m.group(1).strip()
        try:
            decompressed = zlib.decompress(raw)
        except:
            decompressed = raw  # Not compressed
        
        # Search for JPEG start marker in decompressed data
        for jm in re.finditer(rb'\xff\xd8\xff', decompressed):
            end = decompressed.find(b'\xff\xd9', jm.start())
            if end > jm.start():
                jpg = decompressed[jm.start():end+2]
                if len(jpg) > 5000:
                    results.append(('jpeg', jpg))
                    print(f"  Found JPEG: {len(jpg)} bytes", flush=True)
        
        # Search for PNG header
        if b'\x89PNG' in decompressed:
            for pm in re.finditer(rb'\x89PNG', decompressed):
                end = decompressed.find(b'IEND', pm.start())
                if end > pm.start():
                    png = decompressed[pm.start():end+8]
                    if len(png) > 5000:
                        results.append(('png', png))
                        print(f"  Found PNG: {len(png)} bytes", flush=True)
    
    # Method 2: Try decompressing all stream content and look for patterns
    for i, m in enumerate(re.finditer(rb'stream\s(.+?)\nendstream', data, re.DOTALL)):
        raw = m.group(1).strip()
        try:
            decompressed = zlib.decompress(raw)
            text = decompressed.decode('latin-1')
            # Look for numeric patterns that look like invoices
            nums = re.findall(r'\d{8,20}', text)
            if nums:
                print(f"  Stream {i}: found potential invoice number: {nums[0]}", flush=True)
        except:
            pass
    
    return results

if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else '/tmp/inv.pdf'
    print(f"Analyzing: {path}", flush=True)
    images = extract_images_from_pdf(path)
    print(f"Total images found: {len(images)}", flush=True)
    for fmt, img_data in images:
        out = f'/tmp/extracted.{fmt}'
        with open(out, 'wb') as f:
            f.write(img_data)
        print(f"Saved: {out} ({len(img_data)} bytes)", flush=True)
