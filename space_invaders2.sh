#!/bin/sh
python3 -c "$(cat <<'PYTHON'
import sys
import termios
import tty
import select
import os
import time

# Terminal setup
def setup_terminal():
    fd = sys.stdin.fileno()
    old_settings = termios.tcgetattr(fd)
    try:
        tty.setraw(sys.stdin.fileno())
        # Enter alternate screen buffer and hide cursor
        print('\033[?1049h', end='')
        print('\033[?25l', end='')
        sys.stdout.flush()
        return old_settings
    except Exception:
        return old_settings

def restore_terminal(old_settings):
    fd = sys.stdin.fileno()
    termios.tcsetattr(fd, termios.TCSADRAIN, old_settings)
    # Exit alternate screen buffer and show cursor
    print('\033[?25h', end='')
    print('\033[?1049l', end='')
    print('\033[0;0H', end='')
    sys.stdout.flush()

def get_terminal_size():
    try:
        size = os.get_terminal_size()
        return size.lines, size.columns
    except Exception:
        return 24, 80

def draw(rows, cols, ship_row, ship_col, bullets, invaders, score, lives, game_over):
    # Build a screen buffer (list of strings for each row)
    # Initialize with spaces
    screen = [[' ' for _ in range(cols)] for _ in range(rows)]
    
    # Draw HUD (row 0)
    hud = f'Score: {score}  Lives: {lives}  |  Move: ←/→ or h/l  Fire: SPACE  Quit: q'
    for i, ch in enumerate(hud[:cols]):
        if i < cols:
            screen[0][i] = ch
    
    # Draw ship
    if ship_row >= 1 and ship_row < rows and ship_col >= 0:
        # Ship parts: ▲ at (ship_row-1, ship_col+1) and ◢ ◣ at (ship_row, ship_col)
        if ship_col + 1 < cols and ship_row - 1 >= 0:
            screen[ship_row - 1][ship_col + 1] = '▲'
        if ship_col < cols and ship_row < rows:
            screen[ship_row][ship_col] = '◢'
        if ship_col + 1 < cols and ship_row < rows:
            screen[ship_row][ship_col + 1] = ' '
        if ship_col + 2 < cols and ship_row < rows:
            screen[ship_row][ship_col + 2] = '◣'
    
    # Draw bullets
    for br, bc in bullets:
        if br >= 0 and br < rows and bc >= 0 and bc < cols:
            screen[br][bc] = '!'
    
    # Draw invaders
    for inv in invaders:
        ir, ic, alive, sprite = inv
        if alive and ir >= 0 and ir < rows and ic >= 0 and ic < len(sprite) - 0:  # rough check
            # Handle multi-char sprites (Unicode)
            if ic < cols:
                # For emoji, take first char in terms of display - but better to handle
                screen[ir][ic] = sprite[0] if len(sprite) > 0 else ' '
                # For wide chars, this is approximate; but works for most cases
                # If sprite is 1 char display-wise as emoji, we need to be careful
                # But easier: just put the char - terminals handle
                try:
                    screen[ir][ic] = sprite
                except Exception:
                    screen[ir][ic] = sprite[0] if len(sprite) > 0 else ' '
    
    # Game over
    if game_over:
        mid_r = rows // 2
        mid_c = cols // 2
        lines = [
            '=== GAME OVER ===',
            f'Score: {score}',
            'Press q to quit'
        ]
        for j, line in enumerate(lines):
            rpos = mid_r - 1 + j
            if rpos >= 0 and rpos < rows:
                start = max(0, mid_c - len(line) // 2)
                for k, ch in enumerate(line):
                    cpos = start + k
                    if cpos < cols:
                        screen[rpos][cpos] = ch
    
    # Output buffer to screen
    output = []
    for row in screen:
        output.append(''.join(row))
    # Move to home and write
    print('\033[0;0H', end='')
    print('\n'.join(output), end='')
    sys.stdout.flush()

def main():
    old_settings = setup_terminal()
    try:
        rows, cols = get_terminal_size()
        ship_row = rows - 2
        ship_col = cols // 2 - 2
        
        bullets = []  # list of (row, col)
        invaders = []
        inv_start_row = 2
        inv_start_col = 5
        inv_rows = 4
        inv_cols = 8
        for r in range(inv_rows):
            for c in range(inv_cols):
                ir = inv_start_row + r
                ic = inv_start_col + c * 4
                if r == 0:
                    sprite = '👾'
                elif r == 1:
                    sprite = '👽'
                elif r == 2:
                    sprite = '🤖'
                else:
                    sprite = '👹'
                invaders.append([ir, ic, 1, sprite])
        
        score = 0
        lives = 3
        game_over = 0
        inv_dir = 1
        inv_speed = 0
        inv_drop = 0
        last_bullet_time = 0
        bullet_cooldown = 0.2
        
        while True:
            current_time = time.time()
            
            # Input
            while select.select([sys.stdin], [], [], 0)[0]:
                try:
                    key = sys.stdin.read(1)
                    if not key:
                        break
                    if key == 'q' or key == 'Q':
                        break
                    if not game_over:
                        if key == '\x1b':  # ESC
                            # Try to read sequence
                            try:
                                seq = sys.stdin.read(2)
                                if seq == '[D':
                                    ship_col = max(1, ship_col - 2)
                                elif seq == '[C':
                                    ship_col = min(cols - 4, ship_col + 2)
                                elif seq == '[A' or seq == '[B':
                                    if current_time - last_bullet_time > bullet_cooldown:
                                        bullets.append((ship_row - 1, ship_col + 1))
                                        last_bullet_time = current_time
                            except Exception:
                                pass
                        elif key == 'h' or key == 'H' or key == 'a' or key == 'A' or key == 'j' or key == 'J' or key == '\x08':
                            ship_col = max(1, ship_col - 2)
                        elif key == 'l' or key == 'L' or key == 'd' or key == 'D' or key == 'k' or key == 'K':
                            ship_col = min(cols - 4, ship_col + 2)
                        elif key == ' ':
                            if current_time - last_bullet_time > bullet_cooldown:
                                bullets.append((ship_row - 1, ship_col + 1))
                                last_bullet_time = current_time
                        elif ord(key) == 3 or ord(key) == 4:  # Ctrl-C/Ctrl-D
                            break
                        else:
                            if current_time - last_bullet_time > bullet_cooldown:
                                bullets.append((ship_row - 1, ship_col + 1))
                                last_bullet_time = current_time
                except Exception:
                    break
            
            if not game_over:
                # Move bullets
                bullets_new = []
                for br, bc in bullets:
                    br_new = br - 1
                    if br_new > 0:
                        bullets_new.append((br_new, bc))
                bullets = bullets_new
                
                # Move invaders
                inv_speed += 1
                if inv_speed >= 3:
                    inv_speed = 0
                    # Find bounds
                    max_col = 0
                    min_col = cols
                    max_row = 0
                    for inv in invaders:
                        if inv[2] == 1:
                            if inv[1] > max_col:
                                max_col = inv[1]
                            if inv[1] < min_col:
                                min_col = inv[1]
                            if inv[0] > max_row:
                                max_row = inv[0]
                    # Check direction
                    if max_col >= cols - 4 and inv_dir == 1:
                        inv_dir = -1
                        inv_drop = 1
                    elif min_col <= 2 and inv_dir == -1:
                        inv_dir = 1
                        inv_drop = 1
                    # Move
                    for inv in invaders:
                        if inv[2] == 1:
                            if inv_drop:
                                inv[0] += 1
                            inv[1] += inv_dir
                            if inv[0] >= ship_row - 1:
                                game_over = 1
                    inv_drop = 0
                
                # Collisions
                bullets_copy = list(bullets)
                invaders_new = []
                for inv in invaders:
                    if inv[2] == 1:
                        hit = False
                        for i, (br, bc) in enumerate(bullets_copy):
                            if not hit and br == inv[0] and bc >= inv[1] and bc < inv[1] + 2:
                                hit = True
                                bullets_copy.pop(i)
                                score += 10
                                break
                        if not hit:
                            invaders_new.append(inv)
                bullets = bullets_copy
                invaders = invaders_new
                
                # Check win
                alive_count = sum(1 for inv in invaders if inv[2] == 1)
                if alive_count == 0:
                    invaders = []
                    for r in range(inv_rows):
                        for c in range(inv_cols):
                            ir = inv_start_row + r
                            ic = inv_start_col + c * 4
                            if r == 0:
                                sprite = '👾'
                            elif r == 1:
                                sprite = '👽'
                            elif r == 2:
                                sprite = '🤖'
                            else:
                                sprite = '👹'
                            invaders.append([ir, ic, 1, sprite])
                    bullets = []
                    inv_dir = 1
                    inv_drop = 0
            
            draw(rows, cols, ship_row, ship_col, bullets, invaders, score, lives, game_over)
            time.sleep(0.05)
        
    finally:
        restore_terminal(old_settings)

if __name__ == '__main__':
    main()
PYTHON
)"