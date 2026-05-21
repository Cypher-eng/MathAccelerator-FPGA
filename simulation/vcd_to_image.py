from vcd.reader import VCDReader, TokenKind
from PIL import Image
import numpy as np

WIDTH = 640
HEIGHT = 480

def parse_vcd(filename):
    pixels = np.zeros((HEIGHT, WIDTH, 3), dtype=np.uint8)
    
    # Signal values — track current state
    signals = {
        'r': 0, 'g': 0, 'b': 0,
        'valid': 0, 'ready': 0,
        'clk': 0, 'eol': 0, 'sof': 0
    }
    
    # Map VCD identifiers to signal names
    id_map = {}
    
    x, y = 0, 0
    prev_clk = 0
    
    with open(filename) as f:
        reader = VCDReader(f)
        
        for token in reader:
            # Build id_map from header
            if token.kind == TokenKind.VAR:
                if token.data.reference in signals:
                    id_map[token.data.id_code] = token.data.reference
            
            # Read signal changes
            elif token.kind == TokenKind.CHANGE_SCALAR:
                name = id_map.get(token.data.id_code)
                if name:
                    signals[name] = 0 if token.data.value in ('x', 'z') else int(token.data.value)
                    
                    # Detect rising clock edge
                    if name == 'clk' and signals['clk'] == 1 and prev_clk == 0:
                        if signals['valid'] and signals['ready']:
                            if 0 <= x < WIDTH and 0 <= y < HEIGHT:
                                pixels[y, x] = [signals['r'], signals['g'], signals['b']]
                            
                            # Reset on start of frame
                            if signals['sof']:
                                x = 0
                                y = 0
                            # Advance position
                            elif signals['eol']:
                                x = 0
                                y += 1
                            else:
                                x += 1
                    
                    if name == 'clk':
                        prev_clk = signals['clk']
                        
            elif token.kind == TokenKind.CHANGE_VECTOR:
                name = id_map.get(token.data.id_code)
                if name in signals:
                    try:
                        signals[name] = int(token.data.value, 2)
                    except ValueError:
                        signals[name] = 0
    
    return pixels

if __name__ == '__main__':
    print("Parsing VCD file...")
    pixels = parse_vcd('test.vcd')
    
    print("Saving image...")
    image = Image.fromarray(pixels, 'RGB')
    image.save('output.png')
    print("Done — check output.png")